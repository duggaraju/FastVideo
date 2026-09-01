#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [ValidateSet("azure", "external")]
    [string] $DeploymentMode = "azure",
    [string] $ExternalConfigPath,
    [string] $ResourceGroup = "$([Environment]::UserName)-video",
    [string] $Location,
    [string] $Prefix = "video",
    [string] $ImageTag = "latest",
    [ValidateSet("dotnet", "rust")]
    [string] $MediaRuntime = "rust",
    [ValidateSet("storagequeue", "servicebus")]
    [string] $MessageTransport = "storagequeue",
    [string] $KubernetesNamespace,
    [ValidateSet("btbn", "custom")]
    [string] $FfmpegBuild = "btbn",
    [string] $FfmpegVersion = "9.0",
    [string] $Platforms = "linux/amd64,linux/arm64",
    [ValidateRange(1, 2147483647)]
    [int] $MaxAudioDurationSeconds = 21600,
    [switch] $UseLocalDocker = $true,
    [switch] $SkipInfrastructureDeployment,
    [string] $RenderedManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy/rendered.yaml")
)

# This script renders Kubernetes manifests with Kustomize (bases + overlays under
# deploy/k8s/) instead of the old __PLACEHOLDER__ string-replace templating engine.
#
# deploy/k8s/base                    - provider/transport-agnostic resources
# deploy/k8s/overlays/storagequeue   - Storage Queue transport resource variants
# deploy/k8s/overlays/servicebus     - Service Bus transport resource variants
# deploy/k8s/components/providers/azure    - Azure/AKS provider component
# deploy/k8s/components/providers/external - external-cluster provider component
#                                      defaults; every value comes from the user's
#                                      -ExternalConfigPath JSON)
#
# Values only known at deploy time (storage account names, workload identity
# client id, Service Bus namespace, image tags, KEDA trigger metadata, ...) are
# injected by generating a small overlay on disk under deploy/.generated/<name>/
# that layers a transport overlay + provider component and patches in the real
# values. `kubectl kustomize` renders that generated overlay into the final
# manifest; `kubectl apply -k` (or `apply -f -` on the rendered output) applies it.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or later is required."
}

function Assert-NativeCommandSucceeded([string] $Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-ConfigValue([System.Collections.IDictionary] $Config, [string] $Name, $Default = $null) {
    if ($null -ne $Config -and $Config.Contains($Name) -and $null -ne $Config[$Name]) {
        $value = $Config[$Name]
        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and $value -isnot [System.Collections.IDictionary]) {
            return , @($value)
        }
        return $value
    }
    return $Default
}

function Get-RequiredConfigValue([System.Collections.IDictionary] $Config, [string] $Name, [string] $Path) {
    $value = Get-ConfigValue $Config $Name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw "External deployment config '$Path' must define '$Name'."
    }
    return $value
}

function ConvertTo-YamlScalar($Value) {
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [string]) { return ($Value | ConvertTo-Json -Compress) }
    return [string]$Value
}

# Expands "{{TOKEN}}" placeholders inside a single scalar string. This is only used
# for the small, genuinely free-form JSON blob (KEDA scaler type/metadata) that
# still lives in deploy/overlays/azure-config.json; every other per-deploy-run value
# is injected directly as a Kustomize patch/replacement below.
function Expand-Tokens([string] $Value, [System.Collections.IDictionary] $Tokens) {
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $result = $Value
    foreach ($key in $Tokens.Keys) {
        $result = $result.Replace("{{$key}}", [string]$Tokens[$key])
    }
    return $result
}

# Renders a flat string-valued map (KEDA trigger metadata, annotations, pod labels)
# as YAML "key: value" lines at the given indent. Only supports one level of
# nesting because that is all the KEDA/annotation/label schemas ever need.
function Format-FlatYamlMap([System.Collections.IDictionary] $Map, [int] $Indent, [System.Collections.IDictionary] $Tokens = $null) {
    $padding = " " * $Indent
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Map) {
        foreach ($key in $Map.Keys) {
            $value = [string]$Map[$key]
            if ($null -ne $Tokens) { $value = Expand-Tokens $value $Tokens }
            $lines.Add("$padding$key`: $(ConvertTo-YamlScalar $value)")
        }
    }
    return , $lines.ToArray()
}

function ConvertTo-InlineJson($Value) {
    if ($null -eq $Value) {
        return "null"
    }
    return ($Value | ConvertTo-Json -Compress -Depth 20)
}

function Split-YamlDocuments([string] $Yaml) {
    $normalized = $Yaml -replace "`r`n", "`n"
    $documents = [regex]::Split($normalized, "(?m)^---\s*$") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ($_.Trim() + "`n") }
    return , @($documents)
}

function Get-JobTemplateRole([string] $Document) {
    if ($Document -match "(?m)^  name: video-encoder-template\s*$") { return "encode" }
    if ($Document -match "(?m)^  name: video-audio-encoder-template\s*$") { return "audio-encode" }
    if ($Document -match "(?m)^  name: video-stitcher-template\s*$") { return "stitch" }
    throw "Unrecognized rendered job template document."
}

function Render-JobTemplateSet([string] $GeneratedDir, [string] $Runtime, [AllowNull()][string] $CapacityClass) {
    $templateProfile = if ([string]::IsNullOrWhiteSpace($CapacityClass)) { "default" } else { $CapacityClass }
    $capacityClassSuffix = if ([string]::IsNullOrWhiteSpace($CapacityClass)) { "" } else { "-$CapacityClass" }
    $renderDir = Join-Path $GeneratedDir "job-template-build/$Runtime-$templateProfile"
    if (Test-Path -LiteralPath $renderDir) {
        Remove-Item -LiteralPath $renderDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $renderDir -Force | Out-Null

    $runtimeOverlay = "../../../../k8s/jobs/overlays/$Runtime"
    $providerComponent = if ($DeploymentMode -eq "azure") { "../../../../k8s/jobs/components/providers/azure" } else { "../../../../k8s/jobs/components/providers/external" }
    $jobComponents = [System.Collections.Generic.List[string]]::new()
    $jobComponents.Add($providerComponent)

    $patchNames = [System.Collections.Generic.List[string]]::new()
    if ($DeploymentMode -eq "azure") {
        $jobComponents.Add("../../../../k8s/jobs/components/scheduling/azure/$templateProfile")
        $jobPatch = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: video-encoder-template
spec:
  template:
    spec:
      serviceAccountName: $(ConvertTo-YamlScalar $serviceAccountName)
      volumes:
        - name: input-storage
          csi:
            volumeAttributes:
              storageAccount: $(ConvertTo-YamlScalar $inputStorageAccount)
              containerName: $(ConvertTo-YamlScalar $inputStorageContainer)
              ClientID: $(ConvertTo-YamlScalar $workloadClientId)
        - name: output-storage
          csi:
            volumeAttributes:
              storageAccount: $(ConvertTo-YamlScalar $outputStorageAccount)
              containerName: $(ConvertTo-YamlScalar $outputStorageContainer)
              ClientID: $(ConvertTo-YamlScalar $workloadClientId)
---
apiVersion: batch/v1
kind: Job
metadata:
  name: video-audio-encoder-template
spec:
  template:
    spec:
      serviceAccountName: $(ConvertTo-YamlScalar $serviceAccountName)
      volumes:
        - name: input-storage
          csi:
            volumeAttributes:
              storageAccount: $(ConvertTo-YamlScalar $inputStorageAccount)
              containerName: $(ConvertTo-YamlScalar $inputStorageContainer)
              ClientID: $(ConvertTo-YamlScalar $workloadClientId)
        - name: output-storage
          csi:
            volumeAttributes:
              storageAccount: $(ConvertTo-YamlScalar $outputStorageAccount)
              containerName: $(ConvertTo-YamlScalar $outputStorageContainer)
              ClientID: $(ConvertTo-YamlScalar $workloadClientId)
---
apiVersion: batch/v1
kind: Job
metadata:
  name: video-stitcher-template
spec:
  template:
    spec:
      serviceAccountName: $(ConvertTo-YamlScalar $serviceAccountName)
      volumes:
        - name: output-storage
          csi:
            volumeAttributes:
              storageAccount: $(ConvertTo-YamlScalar $outputStorageAccount)
              containerName: $(ConvertTo-YamlScalar $outputStorageContainer)
              ClientID: $(ConvertTo-YamlScalar $workloadClientId)
"@
        Set-Content -LiteralPath (Join-Path $renderDir "patch-storage.yaml") -Value $jobPatch -Encoding UTF8
        $patchNames.Add("patch-storage.yaml")
    } else {
        $scheduleNodeSelector = switch ($CapacityClass) {
          "interruptible" { $mediaNodeSelectorInterruptible }
          "regular" { $mediaNodeSelectorRegular }
          default { $mediaNodeSelector }
        }
        $scheduleTolerations = switch ($CapacityClass) {
          "interruptible" { $mediaTolerationsInterruptible }
          "regular" { $mediaTolerationsRegular }
          default { $mediaTolerations }
        }
        $jobPatch = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: video-encoder-template
spec:
  template:
    metadata:
      labels: $(ConvertTo-InlineJson $podLabels)
    spec:
      serviceAccountName: $(ConvertTo-YamlScalar $serviceAccountName)
      nodeSelector: $(ConvertTo-InlineJson $scheduleNodeSelector)
      tolerations: $(ConvertTo-InlineJson $scheduleTolerations)
      volumes:
        - name: input-storage
          csi:
            driver: $(ConvertTo-YamlScalar $storageCsiDriver)
            volumeAttributes: $(ConvertTo-InlineJson $inputCsiVolumeAttributes)
        - name: output-storage
          csi:
            driver: $(ConvertTo-YamlScalar $storageCsiDriver)
            volumeAttributes: $(ConvertTo-InlineJson $outputCsiVolumeAttributes)
---
apiVersion: batch/v1
kind: Job
metadata:
  name: video-audio-encoder-template
spec:
  template:
    metadata:
      labels: $(ConvertTo-InlineJson $podLabels)
    spec:
      serviceAccountName: $(ConvertTo-YamlScalar $serviceAccountName)
      nodeSelector: $(ConvertTo-InlineJson $scheduleNodeSelector)
      tolerations: $(ConvertTo-InlineJson $scheduleTolerations)
      volumes:
        - name: input-storage
          csi:
            driver: $(ConvertTo-YamlScalar $storageCsiDriver)
            volumeAttributes: $(ConvertTo-InlineJson $inputCsiVolumeAttributes)
        - name: output-storage
          csi:
            driver: $(ConvertTo-YamlScalar $storageCsiDriver)
            volumeAttributes: $(ConvertTo-InlineJson $outputCsiVolumeAttributes)
---
apiVersion: batch/v1
kind: Job
metadata:
  name: video-stitcher-template
spec:
  template:
    metadata:
      labels: $(ConvertTo-InlineJson $podLabels)
    spec:
      serviceAccountName: $(ConvertTo-YamlScalar $serviceAccountName)
      nodeSelector: $(ConvertTo-InlineJson $scheduleNodeSelector)
      tolerations: $(ConvertTo-InlineJson $scheduleTolerations)
      volumes:
        - name: output-storage
          csi:
            driver: $(ConvertTo-YamlScalar $storageCsiDriver)
            volumeAttributes: $(ConvertTo-InlineJson $outputCsiVolumeAttributes)
"@
        Set-Content -LiteralPath (Join-Path $renderDir "patch-external.yaml") -Value $jobPatch -Encoding UTF8
        $patchNames.Add("patch-external.yaml")
    }

    $resourcesYaml = "  - $runtimeOverlay"
    $componentsYaml = ($jobComponents | ForEach-Object { "  - $_" }) -join "`n"
    $patchesYaml = if ($patchNames.Count -eq 0) { "  []" } else { ($patchNames | ForEach-Object { "  - path: $_" }) -join "`n" }
    $imageSuffix = if ($Runtime -eq "rust") { "rust" } else { "dotnet" }
    $imagesYaml = @"
  - name: video-encoder-$imageSuffix
    newName: $imageRepository/video-encoder-$imageSuffix
    newTag: "$ImageTag"
  - name: video-audio-encoder-$imageSuffix
    newName: $imageRepository/video-audio-encoder-$imageSuffix
    newTag: "$ImageTag"
  - name: video-stitcher-$imageSuffix
    newName: $imageRepository/video-stitcher-$imageSuffix
    newTag: "$ImageTag"
"@
    $kustomization = @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
$resourcesYaml
components:
$componentsYaml
patches:
$patchesYaml
images:
$imagesYaml
"@
    Set-Content -LiteralPath (Join-Path $renderDir "kustomization.yaml") -Value $kustomization -Encoding UTF8

    $manifest = (kubectl kustomize $renderDir | Out-String)
    Assert-NativeCommandSucceeded "Rendering $Runtime/$templateProfile job templates with kubectl kustomize"

    $outputDir = Join-Path $GeneratedDir "job-templates"
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($document in (Split-YamlDocuments $manifest)) {
        $role = Get-JobTemplateRole $document
        $fileName = "$role-$Runtime$capacityClassSuffix.yaml"
        Set-Content -LiteralPath (Join-Path $outputDir $fileName) -Value $document -Encoding UTF8
        $entries.Add("      - $fileName=job-templates/$fileName")
    }
    return , $entries.ToArray()
}

$deployment = $null
$deploymentName = $null
$kubeContext = $null
$kubectlContextArgs = @()
$serviceBusNamespace = ""
$inputStorageAccount = ""
$inputStorageContainer = ""
$outputStorageAccount = ""
$outputStorageContainer = ""
$workloadClientId = ""
$serviceAccountName = "video-worker"
$serviceAccountAnnotations = @{}
$scaler = @{ mode = "none" }
$imageRepository = ""
$storageCsiDriver = ""
$inputCsiVolumeAttributes = @{}
$outputCsiVolumeAttributes = @{}
$podLabels = @{}
$controlPlaneNodeSelector = @{}
$controlPlaneTolerations = @()
$mediaNodeSelector = @{}
$mediaNodeSelectorInterruptible = @{}
$mediaNodeSelectorRegular = @{}
$mediaTolerations = @()
$mediaTolerationsInterruptible = @()
$mediaTolerationsRegular = @()

if ($DeploymentMode -eq "external") {
    if ($SkipInfrastructureDeployment) {
        throw "-SkipInfrastructureDeployment is only valid with -DeploymentMode azure."
    }
    if ([string]::IsNullOrWhiteSpace($ExternalConfigPath)) {
        throw "-ExternalConfigPath is required with -DeploymentMode external."
    }
    $resolvedConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExternalConfigPath)
    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "External deployment config '$resolvedConfigPath' does not exist."
    }
    try {
        $external = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        throw "External deployment config '$resolvedConfigPath' is not valid JSON: $($_.Exception.Message)"
    }

    $kubeContext = [string](Get-RequiredConfigValue $external "kubeContext" $resolvedConfigPath)
    $kubectlContextArgs = @("--context", $kubeContext)
    $contextRecord = kubectl config get-contexts $kubeContext --no-headers
    Assert-NativeCommandSucceeded "Finding Kubernetes context '$kubeContext'"
    if ([string]::IsNullOrWhiteSpace($contextRecord)) {
        throw "Kubernetes context '$kubeContext' was not found in the current kubeconfig."
    }

    if ([string]::IsNullOrWhiteSpace($KubernetesNamespace)) {
        $KubernetesNamespace = [string](Get-ConfigValue $external "namespace" "video-$MessageTransport")
    }
    $imageRepository = ([string](Get-RequiredConfigValue $external "imageRepository" $resolvedConfigPath)).TrimEnd("/")
    $workloadClientId = [string](Get-RequiredConfigValue $external "workloadClientId" $resolvedConfigPath)
    $serviceAccountName = [string](Get-RequiredConfigValue $external "serviceAccountName" $resolvedConfigPath)
    $serviceAccountAnnotations = Get-ConfigValue $external "serviceAccountAnnotations" @{}

    $storage = Get-RequiredConfigValue $external "storage" $resolvedConfigPath
    if ($storage -isnot [System.Collections.IDictionary]) {
        throw "External deployment config '$resolvedConfigPath' property 'storage' must be a JSON object."
    }
    $inputStorageAccount = [string](Get-RequiredConfigValue $storage "inputAccountName" "storage")
    $inputStorageContainer = [string](Get-RequiredConfigValue $storage "inputContainer" "storage")
    $outputStorageAccount = [string](Get-RequiredConfigValue $storage "outputAccountName" "storage")
    $outputStorageContainer = [string](Get-RequiredConfigValue $storage "outputContainer" "storage")
    $storageCsiDriver = [string](Get-RequiredConfigValue $storage "csiDriver" "storage")
    $inputCsiVolumeAttributes = Get-RequiredConfigValue $storage "inputVolumeAttributes" "storage"
    $outputCsiVolumeAttributes = Get-RequiredConfigValue $storage "outputVolumeAttributes" "storage"
    $podLabels = Get-ConfigValue $external "podLabels" @{}
    $controlPlaneNodeSelector = Get-ConfigValue $external "controlPlaneNodeSelector" @{}
    $controlPlaneTolerations = @(Get-ConfigValue $external "controlPlaneTolerations" @())
    $mediaNodeSelector = Get-ConfigValue $external "mediaNodeSelector" @{}
    $mediaNodeSelectorInterruptible = Get-ConfigValue $external "mediaNodeSelectorInterruptible" @{}
    $mediaNodeSelectorRegular = Get-ConfigValue $external "mediaNodeSelectorRegular" @{}
    $mediaTolerations = @(Get-ConfigValue $external "mediaTolerations" @())
    $mediaTolerationsInterruptible = @(Get-ConfigValue $external "mediaTolerationsInterruptible" @())
    $mediaTolerationsRegular = @(Get-ConfigValue $external "mediaTolerationsRegular" @())

    $serviceBusNamespace = [string](Get-ConfigValue $external "serviceBusNamespace" "")
    if ($MessageTransport -eq "servicebus" -and [string]::IsNullOrWhiteSpace($serviceBusNamespace)) {
        throw "External deployment config '$resolvedConfigPath' must define 'serviceBusNamespace' for the servicebus transport."
    }
    $scaler = Get-ConfigValue $external "scaler" @{ mode = "none" }
    if ($scaler -isnot [System.Collections.IDictionary]) {
        throw "External deployment config '$resolvedConfigPath' property 'scaler' must be a JSON object."
    }
} else {
    if (-not [string]::IsNullOrWhiteSpace($ExternalConfigPath)) {
        throw "-ExternalConfigPath is only valid with -DeploymentMode azure."
    }
    if ([string]::IsNullOrWhiteSpace($KubernetesNamespace)) {
        $KubernetesNamespace = "video-$MessageTransport"
    }

    if ($SkipInfrastructureDeployment) {
        $deploymentName = az deployment group list `
            --resource-group $ResourceGroup `
            --query "sort_by([?properties.provisioningState=='Succeeded' && properties.outputs.acrName != null && properties.outputs.messageTransport.value=='$MessageTransport'], &properties.timestamp)[-1].name" `
            --output tsv
        Assert-NativeCommandSucceeded "Finding the latest successful video infrastructure deployment"
        if ([string]::IsNullOrWhiteSpace($deploymentName)) {
            throw "No successful video infrastructure deployment was found in resource group '$ResourceGroup'."
        }
        $deploymentJson = az deployment group show `
            --resource-group $ResourceGroup `
            --name $deploymentName `
            --query properties.outputs `
            --output json
        Assert-NativeCommandSucceeded "Reading outputs from deployment '$deploymentName'"
        Write-Host "Skipping infrastructure deployment; using outputs from '$deploymentName'."
    } else {
        if ([string]::IsNullOrWhiteSpace($Location)) {
            throw "Location is required unless -SkipInfrastructureDeployment is specified."
        }
        az group create --name $ResourceGroup --location $Location --output none
        Assert-NativeCommandSucceeded "Creating or updating resource group '$ResourceGroup'"
        $deploymentJson = az deployment group create `
            --resource-group $ResourceGroup `
            --name "video-$MessageTransport" `
            --template-file (Join-Path $root "infra/main.bicep") `
            --parameters prefix=$Prefix messageTransport=$MessageTransport kubernetesNamespace=$KubernetesNamespace `
            --query properties.outputs `
            --output json
        Assert-NativeCommandSucceeded "Deploying Azure resources; image builds and Kubernetes deployment were not started"
    }
    if ([string]::IsNullOrWhiteSpace($deploymentJson)) {
        throw "Azure resource deployment outputs are empty."
    }
    $deployment = $deploymentJson | ConvertFrom-Json
    $deployedTransport = [string]$deployment.messageTransport.value
    if ([string]::IsNullOrWhiteSpace($deployedTransport)) {
        $deployedTransport = if (-not [string]::IsNullOrWhiteSpace([string]$deployment.outputQueueServiceUri.value)) {
            "storagequeue"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$deployment.serviceBusNamespace.value)) {
            "servicebus"
        } else {
            throw "Deployment outputs do not identify a supported message transport."
        }
    }
    if ($deployedTransport -ne $MessageTransport) {
        throw "Deployment uses '$deployedTransport' but -MessageTransport requested '$MessageTransport'. Deploy infrastructure without -SkipInfrastructureDeployment to change it."
    }
    $deployedKubernetesNamespace = [string]$deployment.kubernetesNamespace.value
    if ($SkipInfrastructureDeployment -and
        -not [string]::IsNullOrWhiteSpace($deployedKubernetesNamespace) -and
        $deployedKubernetesNamespace -ne $KubernetesNamespace) {
        throw "Deployment '$deploymentName' federates namespace '$deployedKubernetesNamespace', not '$KubernetesNamespace'. Deploy infrastructure without -SkipInfrastructureDeployment to add the namespace federation."
    }

    $buildImageParameters = @{
        AcrName = $deployment.acrName.value
        ImageTag = $ImageTag
        MessageTransport = $MessageTransport
        FfmpegBuild = $FfmpegBuild
        FfmpegVersion = $FfmpegVersion
        Platforms = $Platforms
        AcrBuild = -not $UseLocalDocker
    }
    & (Join-Path $PSScriptRoot "build-images.ps1") @buildImageParameters

    az aks get-credentials `
        --resource-group $ResourceGroup `
        --name $deployment.aksName.value `
        --overwrite-existing
    Assert-NativeCommandSucceeded "Getting AKS credentials"

    $imageRepository = ([string]$deployment.acrLoginServer.value).TrimEnd("/")
    $serviceBusNamespace = [string]$deployment.serviceBusNamespace.value
    $inputStorageAccount = [string]$deployment.inputStorageName.value
    $inputStorageContainer = [string]$deployment.inputContainerName.value
    $outputStorageAccount = [string]$deployment.outputStorageName.value
    $outputStorageContainer = [string]$deployment.outputContainerName.value
    $workloadClientId = [string]$deployment.workloadClientId.value
    $serviceAccountAnnotations = @{ "azure.workload.identity/client-id" = $workloadClientId }
    $storageCsiDriver = "blob.csi.azure.com"

    # deploy/overlays/azure-config.json is now a small JSON "profile" of the one
    # thing that still needs deploy-time templating: KEDA scaler type/metadata.
    # Every other Azure-specific static default (node selectors, tolerations, CSI
    # driver, workload-identity pod label) is Kustomize-native and lives in
    # deploy/k8s/components/providers/azure/ and deploy/k8s/jobs/components/providers/azure/.
    $azureOverlayPath = Join-Path $root "deploy/overlays/azure-config.json"
    try {
        $azureOverlay = Get-Content -LiteralPath $azureOverlayPath -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        throw "Azure overlay config '$azureOverlayPath' is not valid JSON: $($_.Exception.Message)"
    }
    $azureScalers = Get-RequiredConfigValue $azureOverlay "scaler" $azureOverlayPath
    $scaler = Get-RequiredConfigValue $azureScalers $MessageTransport $azureOverlayPath
}

$overlayTokens = @{
    WORKLOAD_CLIENT_ID = $workloadClientId
    INPUT_STORAGE_ACCOUNT = $inputStorageAccount
    INPUT_STORAGE_CONTAINER = $inputStorageContainer
    OUTPUT_STORAGE_ACCOUNT = $outputStorageAccount
    OUTPUT_STORAGE_CONTAINER = $outputStorageContainer
    SERVICE_BUS_NAMESPACE_SHORT = $(if ([string]::IsNullOrWhiteSpace($serviceBusNamespace)) { "" } else { $serviceBusNamespace.Split(".")[0] })
}

$scalerMode = [string](Get-ConfigValue $scaler "mode" "none")
if ($scalerMode -notin @("none", "keda")) {
    throw "Scaler mode must be 'keda' or 'none'; got '$scalerMode'."
}
$triggerAuthenticationName = [string](Get-ConfigValue $scaler "authenticationRef" "video-workload-identity")
$triggerAuthenticationSpec = Get-ConfigValue $scaler "triggerAuthentication"

$analyzerImageName = if ($MessageTransport -eq "storagequeue") { "video-analysis-storagequeue" } else { "video-analysis-servicebus" }
$completionImageName = if ($MessageTransport -eq "storagequeue") { "video-completion-storagequeue" } else { "video-completion-servicebus" }

# --- Compute the deploy-time ConfigMap literal overrides (merged over the ---
# --- transport/provider defaults already baked into the Kustomize tree).   ---
$configLiterals = [System.Collections.Generic.List[string]]::new()
$configLiterals.Add("Kubernetes__Namespace=$KubernetesNamespace")
$configLiterals.Add("Kubernetes__ServiceAccountName=$serviceAccountName")
$configLiterals.Add("WorkloadIdentity__ClientId=$workloadClientId")
if ($MessageTransport -eq "servicebus") {
    $configLiterals.Add("ServiceBus__Namespace=$serviceBusNamespace")
}
$configLiterals.Add("Storage__InputAccountName=$inputStorageAccount")
$configLiterals.Add("Storage__InputContainer=$inputStorageContainer")
$configLiterals.Add("Storage__OutputAccountName=$outputStorageAccount")
$configLiterals.Add("Storage__OutputContainer=$outputStorageContainer")
$configLiterals.Add("Storage__WorkingContainer=$outputStorageContainer")
$configLiterals.Add("Encoding__MediaRuntimeDefault=$MediaRuntime")
$configLiterals.Add("Encoding__MaxAudioDurationSeconds=$MaxAudioDurationSeconds")
$configLiterals.Add("Images__Dotnet__Encoder=$imageRepository/video-encoder-dotnet:$ImageTag")
$configLiterals.Add("Images__Dotnet__AudioEncoder=$imageRepository/video-audio-encoder-dotnet:$ImageTag")
$configLiterals.Add("Images__Dotnet__Stitcher=$imageRepository/video-stitcher-dotnet:$ImageTag")
$configLiterals.Add("Images__Rust__Encoder=$imageRepository/video-encoder-rust:$ImageTag")
$configLiterals.Add("Images__Rust__AudioEncoder=$imageRepository/video-audio-encoder-rust:$ImageTag")
$configLiterals.Add("Images__Rust__Stitcher=$imageRepository/video-stitcher-rust:$ImageTag")

# --- Write the deploy-time generated overlay. ---
$generatedName = "$DeploymentMode-$MessageTransport"
$generatedDir = Join-Path $root "deploy/.generated/$generatedName"
if (Test-Path -LiteralPath $generatedDir) {
    Remove-Item -LiteralPath $generatedDir -Recurse -Force
}
New-Item -ItemType Directory -Path $generatedDir -Force | Out-Null

$providerOverlayRelativePath = if ($DeploymentMode -eq "azure") { "../../k8s/components/providers/azure" } else { "../../k8s/components/providers/external" }
$transportOverlayRelativePath = "../../k8s/overlays/$MessageTransport"

$analyzerReplicas = if ($scalerMode -eq "keda") { 0 } else { 1 }

$patchAnalyzer = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: video-analyzer
spec:
  replicas: $analyzerReplicas
  template:
    spec:
      serviceAccountName: $serviceAccountName
      containers:
        - name: analyzer
          image: "$imageRepository/$($analyzerImageName):$ImageTag"
      volumes:
        - name: input-storage
          csi:
            volumeAttributes:
              storageAccount: $(ConvertTo-YamlScalar $inputStorageAccount)
              containerName: $(ConvertTo-YamlScalar $inputStorageContainer)
              ClientID: $(ConvertTo-YamlScalar $workloadClientId)
        - name: output-storage
          csi:
            volumeAttributes:
              storageAccount: $(ConvertTo-YamlScalar $outputStorageAccount)
              containerName: $(ConvertTo-YamlScalar $outputStorageContainer)
              ClientID: $(ConvertTo-YamlScalar $workloadClientId)
"@
Set-Content -LiteralPath (Join-Path $generatedDir "patch-analyzer.yaml") -Value $patchAnalyzer -Encoding UTF8

$patchCompletion = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: video-completion
spec:
  template:
    spec:
      serviceAccountName: $serviceAccountName
      containers:
        - name: completion
          image: "$imageRepository/$($completionImageName):$ImageTag"
"@
Set-Content -LiteralPath (Join-Path $generatedDir "patch-completion.yaml") -Value $patchCompletion -Encoding UTF8

$annotationLines = Format-FlatYamlMap $serviceAccountAnnotations 4
$annotationsBlock = if ($annotationLines.Count -eq 0) { "  annotations: {}" } else { "  annotations:`n$($annotationLines -join "`n")" }
$customServiceAccountResourcePath = $null
$deleteServiceAccountPatchPath = $null
if ($serviceAccountName -eq "video-worker") {
    $patchServiceAccount = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: video-worker
$annotationsBlock
"@
    Set-Content -LiteralPath (Join-Path $generatedDir "patch-serviceaccount.yaml") -Value $patchServiceAccount -Encoding UTF8
} else {
    $customServiceAccount = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $serviceAccountName
$annotationsBlock
"@
    $customServiceAccountResourcePath = Join-Path $generatedDir "serviceaccount-custom.yaml"
    Set-Content -LiteralPath $customServiceAccountResourcePath -Value $customServiceAccount -Encoding UTF8

    $deleteServiceAccount = @'
$patch: delete
apiVersion: v1
kind: ServiceAccount
metadata:
  name: video-worker
'@
    $deleteServiceAccountPatchPath = Join-Path $generatedDir "patch-delete-serviceaccount.yaml"
    Set-Content -LiteralPath $deleteServiceAccountPatchPath -Value $deleteServiceAccount -Encoding UTF8
}

$patchRoleBinding = @"
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: video-job-manager
subjects:
  - kind: ServiceAccount
    name: $serviceAccountName
"@
Set-Content -LiteralPath (Join-Path $generatedDir "patch-rolebinding.yaml") -Value $patchRoleBinding -Encoding UTF8

$extraAnalyzerPatchPath = $null
$extraCompletionPatchPath = $null
if ($DeploymentMode -eq "external") {
    $patchExternalAnalyzer = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: video-analyzer
spec:
  template:
    metadata:
      labels: $(ConvertTo-InlineJson $podLabels)
    spec:
      nodeSelector: $(ConvertTo-InlineJson $controlPlaneNodeSelector)
      tolerations: $(ConvertTo-InlineJson $controlPlaneTolerations)
      volumes:
        - name: input-storage
          csi:
            driver: $(ConvertTo-YamlScalar $storageCsiDriver)
            volumeAttributes: $(ConvertTo-InlineJson $inputCsiVolumeAttributes)
        - name: output-storage
          csi:
            driver: $(ConvertTo-YamlScalar $storageCsiDriver)
            volumeAttributes: $(ConvertTo-InlineJson $outputCsiVolumeAttributes)
"@
    $extraAnalyzerPatchPath = Join-Path $generatedDir "patch-external-analyzer.yaml"
    Set-Content -LiteralPath $extraAnalyzerPatchPath -Value $patchExternalAnalyzer -Encoding UTF8

    $patchExternalCompletion = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: video-completion
spec:
  template:
    metadata:
      labels: $(ConvertTo-InlineJson $podLabels)
    spec:
      nodeSelector: $(ConvertTo-InlineJson $controlPlaneNodeSelector)
      tolerations: $(ConvertTo-InlineJson $controlPlaneTolerations)
"@
    $extraCompletionPatchPath = Join-Path $generatedDir "patch-external-completion.yaml"
    Set-Content -LiteralPath $extraCompletionPatchPath -Value $patchExternalCompletion -Encoding UTF8
}

$jobTemplateFileEntries = [System.Collections.Generic.List[string]]::new()
foreach ($runtime in @("dotnet", "rust")) {
  foreach ($capacityClass in @($null, "interruptible", "regular")) {
    foreach ($entry in (Render-JobTemplateSet $generatedDir $runtime $capacityClass)) {
            $jobTemplateFileEntries.Add($entry)
        }
    }
}

$kustomizationResources = [System.Collections.Generic.List[string]]::new()
$kustomizationResources.Add($transportOverlayRelativePath)
if ($null -ne $customServiceAccountResourcePath) {
    $kustomizationResources.Add("./$(Split-Path -Leaf $customServiceAccountResourcePath)")
}

$kustomizationComponents = [System.Collections.Generic.List[string]]::new()
$kustomizationComponents.Add($providerOverlayRelativePath)

if ($scalerMode -eq "keda") {
    $metadataLines = Format-FlatYamlMap (Get-RequiredConfigValue $scaler "metadata" "scaler") 8 $overlayTokens
    $scalerType = Expand-Tokens ([string](Get-RequiredConfigValue $scaler "type" "scaler")) $overlayTokens
    $scaledObject = @"
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: video-analyzer
  namespace: $KubernetesNamespace
spec:
  scaleTargetRef:
    name: video-analyzer
  pollingInterval: 10
  cooldownPeriod: 60
  minReplicaCount: 0
  maxReplicaCount: 10
  triggers:
    - type: $(ConvertTo-YamlScalar $scalerType)
      metadata:
$($metadataLines -join "`n")
      authenticationRef:
        name: $triggerAuthenticationName
"@
    Set-Content -LiteralPath (Join-Path $generatedDir "scaledobject.yaml") -Value $scaledObject -Encoding UTF8

    if ($null -ne $triggerAuthenticationSpec -and $triggerAuthenticationSpec.Count -gt 0) {
        $specLines = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $triggerAuthenticationSpec.Keys) {
            $child = $triggerAuthenticationSpec[$key]
            if ($child -is [System.Collections.IDictionary]) {
                $specLines.Add("  $key`:")
                foreach ($line in (Format-FlatYamlMap $child 4 $overlayTokens)) { $specLines.Add($line) }
            } else {
                $specLines.Add("  $key`: $(ConvertTo-YamlScalar (Expand-Tokens ([string]$child) $overlayTokens))")
            }
        }
        $triggerAuthentication = @"
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: $triggerAuthenticationName
  namespace: $KubernetesNamespace
spec:
$($specLines -join "`n")
"@
        Set-Content -LiteralPath (Join-Path $generatedDir "triggerauthentication.yaml") -Value $triggerAuthentication -Encoding UTF8
        $kustomizationResources.Add("./triggerauthentication.yaml")
    }
    $kustomizationResources.Add("./scaledobject.yaml")
}

$literalsYaml = ($configLiterals | ForEach-Object { "      - $_" }) -join "`n"
$jobTemplateFilesYaml = $jobTemplateFileEntries -join "`n"
$resourcesYaml = ($kustomizationResources | ForEach-Object { "  - $_" }) -join "`n"
$componentsYaml = ($kustomizationComponents | ForEach-Object { "  - $_" }) -join "`n"

$kustomizationPatches = [System.Collections.Generic.List[string]]::new()
$kustomizationPatches.Add("  - path: patch-analyzer.yaml")
$kustomizationPatches.Add("  - path: patch-completion.yaml")
if ($serviceAccountName -eq "video-worker") {
    $kustomizationPatches.Add("  - path: patch-serviceaccount.yaml")
} elseif ($null -ne $deleteServiceAccountPatchPath) {
    $kustomizationPatches.Add("  - path: $(Split-Path -Leaf $deleteServiceAccountPatchPath)")
}
$kustomizationPatches.Add("  - path: patch-rolebinding.yaml")
if ($null -ne $extraAnalyzerPatchPath) {
    $kustomizationPatches.Add("  - path: $(Split-Path -Leaf $extraAnalyzerPatchPath)")
}
if ($null -ne $extraCompletionPatchPath) {
    $kustomizationPatches.Add("  - path: $(Split-Path -Leaf $extraCompletionPatchPath)")
}
$patchesYaml = $kustomizationPatches -join "`n"

$kustomization = @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Generated by scripts/deploy.ps1 - do not edit by hand, do not commit.
namespace: $KubernetesNamespace
resources:
$resourcesYaml
components:
$componentsYaml
patches:
$patchesYaml
configMapGenerator:
  - name: video-config
    behavior: merge
    literals:
$literalsYaml
  - name: video-job-templates
    behavior: create
    files:
$jobTemplateFilesYaml
generatorOptions:
  disableNameSuffixHash: true
"@
Set-Content -LiteralPath (Join-Path $generatedDir "kustomization.yaml") -Value $kustomization -Encoding UTF8

$manifest = kubectl kustomize $generatedDir
Assert-NativeCommandSucceeded "Rendering the Kubernetes manifest with kubectl kustomize"
if ($manifest -cmatch "__[A-Z0-9_]+__" -or $manifest -cmatch "\{\{[A-Z0-9_]+\}\}") {
    throw "Rendered Kubernetes manifest contains an unresolved placeholder '$($Matches[0])'."
}

$renderedManifest = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RenderedManifestPath)
Set-Content -Path $renderedManifest -Value $manifest -Encoding UTF8
kubectl @kubectlContextArgs apply --filename $renderedManifest
Assert-NativeCommandSucceeded "Applying the Kubernetes manifest"

$analysisDeployment = "video-analyzer"
$completionDeployment = "video-completion"
if ($scalerMode -eq "keda") {
    $unpausePatch = '{"metadata":{"annotations":{"autoscaling.keda.sh/paused":null,"autoscaling.keda.sh/paused-replicas":null}}}'
    kubectl @kubectlContextArgs patch "scaledobject/$analysisDeployment" --namespace $KubernetesNamespace --type merge --patch $unpausePatch
    Assert-NativeCommandSucceeded "Unpausing selected ScaledObject '$analysisDeployment'"
}

kubectl @kubectlContextArgs rollout restart `
    --namespace $KubernetesNamespace `
    "deployment/$analysisDeployment" `
    "deployment/$completionDeployment"
Assert-NativeCommandSucceeded "Restarting video deployments to use the configured images"

if ($DeploymentMode -eq "azure") {
    Write-Host "Deployed video pipeline to $($deployment.aksName.value) in namespace $KubernetesNamespace with $MessageTransport control plane, $MediaRuntime media workers, and image tag $ImageTag"
    if ($MessageTransport -eq "storagequeue") {
        Write-Host "Storage Queue input queue: https://$outputStorageAccount.queue.core.windows.net/video-submitted"
        Write-Host "Storage Queue result queue: https://$outputStorageAccount.queue.core.windows.net/video-results"
    } else {
        Write-Host "Service Bus input queue: $serviceBusNamespace/video-submitted"
        Write-Host "Service Bus result queue: $serviceBusNamespace/video-results"
    }
    Write-Host "Input blob container: $($deployment.inputStorageServiceUri.value)/$inputStorageContainer"
    Write-Host "Output blob container: $($deployment.outputStorageServiceUri.value)/$outputStorageContainer"
} else {
    Write-Host "Deployed external-cluster profile to context '$kubeContext' in namespace '$KubernetesNamespace' using images from '$imageRepository'."
}
