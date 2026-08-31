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
        return $Config[$Name]
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

function ConvertTo-YamlLines($Value, [int] $Indent = 0) {
    $padding = " " * $Indent
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $child = $Value[$key]
            if ($child -is [System.Collections.IDictionary] -or
                ($child -is [System.Collections.IEnumerable] -and $child -isnot [string])) {
                $lines.Add("$padding$key`:")
                foreach ($line in (ConvertTo-YamlLines $child ($Indent + 2))) { $lines.Add($line) }
            } else {
                $lines.Add("$padding$key`: $(ConvertTo-YamlScalar $child)")
            }
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($child in $Value) {
            if ($child -is [System.Collections.IDictionary] -or
                ($child -is [System.Collections.IEnumerable] -and $child -isnot [string])) {
                $lines.Add("$padding-")
                foreach ($line in (ConvertTo-YamlLines $child ($Indent + 2))) { $lines.Add($line) }
            } else {
                $lines.Add("$padding- $(ConvertTo-YamlScalar $child)")
            }
        }
    }
    return $lines
}

function ConvertTo-YamlProperty(
    [string] $Name,
    $Value,
    [int] $Indent,
    [switch] $OmitWhenEmpty
) {
    $items = @(ConvertTo-YamlLines $Value ($Indent + 2))
    if ($items.Count -eq 0) {
        if ($OmitWhenEmpty) { return "" }
        return "$((' ' * $Indent))$Name`: {}"
    }
    return (@("$((' ' * $Indent))$Name`:") + $items) -join "`n"
}

function ConvertTo-JsonConfig($Value) {
    if ($null -eq $Value) { return "{}" }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return "{}" }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return "[]" }
        return $items | ConvertTo-Json -Compress -Depth 20 -AsArray
    }
    return $Value | ConvertTo-Json -Compress -Depth 20
}

function New-TriggerAuthenticationResource(
    [string] $Namespace,
    [string] $Name,
    [System.Collections.IDictionary] $Spec
) {
    if ($null -eq $Spec -or $Spec.Count -eq 0) { return "" }
    $specLines = ConvertTo-YamlLines $Spec 2
    return @"
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: $Name
  namespace: $Namespace
spec:
$($specLines -join "`n")
"@
}

function New-ScalerResource(
    [string] $Namespace,
    [string] $DeploymentName,
    [System.Collections.IDictionary] $Scaler
) {
    $mode = [string](Get-ConfigValue $Scaler "mode" "none")
    if ($mode -eq "none") { return "" }
    if ($mode -ne "keda") {
        throw "Scaler mode must be 'keda' or 'none'; got '$mode'."
    }
    $type = [string](Get-RequiredConfigValue $Scaler "type" "scaler")
    $metadata = Get-RequiredConfigValue $Scaler "metadata" "scaler"
    if ($metadata -isnot [System.Collections.IDictionary]) {
        throw "Scaler 'metadata' must be a JSON object."
    }
    $metadataLines = ConvertTo-YamlLines $metadata 8
    $authenticationRef = [string](Get-ConfigValue $Scaler "authenticationRef" "")
    $authenticationBlock = if ([string]::IsNullOrWhiteSpace($authenticationRef)) {
        ""
    } else {
        "`n      authenticationRef:`n        name: $(ConvertTo-YamlScalar $authenticationRef)"
    }
    return @"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: $DeploymentName
  namespace: $Namespace
spec:
  scaleTargetRef:
    name: $DeploymentName
  pollingInterval: 10
  cooldownPeriod: 60
  minReplicaCount: 0
  maxReplicaCount: 10
  triggers:
    - type: $(ConvertTo-YamlScalar $type)
      metadata:
$($metadataLines -join "`n")$authenticationBlock
"@
}

$deployment = $null
$deploymentName = $null
$kubectlContextArgs = @()
$serviceBusNamespace = ""
$inputStorageAccount = ""
$inputStorageContainer = ""
$outputStorageAccount = ""
$outputStorageContainer = ""
$workloadClientId = ""
$serviceAccountName = "video-worker"
$serviceAccountAnnotations = @{}
$podLabels = @{}
$controlPlaneNodeSelector = @{}
$controlPlaneTolerations = @()
$mediaNodeSelectorSpot = @{}
$mediaNodeSelectorRegular = @{}
$mediaTolerationsSpot = @()
$mediaTolerationsRegular = @()
$storageCsiDriver = ""
$inputCsiVolumeAttributes = @{}
$outputCsiVolumeAttributes = @{}
$scaler = @{}
$triggerAuthentication = $null
$imageRepository = ""

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
    $podLabels = Get-ConfigValue $external "podLabels" @{}
    $controlPlaneNodeSelector = Get-ConfigValue $external "controlPlaneNodeSelector" @{}
    $controlPlaneTolerations = Get-ConfigValue $external "controlPlaneTolerations" @()
    $mediaNodeSelectorSpot = Get-ConfigValue $external "mediaNodeSelectorSpot" @{}
    $mediaNodeSelectorRegular = Get-ConfigValue $external "mediaNodeSelectorRegular" @{}
    $mediaTolerationsSpot = Get-ConfigValue $external "mediaTolerationsSpot" @()
    $mediaTolerationsRegular = Get-ConfigValue $external "mediaTolerationsRegular" @()

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

    $serviceBusNamespace = [string](Get-ConfigValue $external "serviceBusNamespace" "")
    if ($MessageTransport -eq "servicebus" -and [string]::IsNullOrWhiteSpace($serviceBusNamespace)) {
        throw "External deployment config '$resolvedConfigPath' must define 'serviceBusNamespace' for the servicebus transport."
    }
    $scaler = Get-ConfigValue $external "scaler" @{ mode = "none" }
    if ($scaler -isnot [System.Collections.IDictionary]) {
        throw "External deployment config '$resolvedConfigPath' property 'scaler' must be a JSON object."
    }
    $triggerAuthentication = Get-ConfigValue $scaler "triggerAuthentication"
} else {
    if (-not [string]::IsNullOrWhiteSpace($ExternalConfigPath)) {
        throw "-ExternalConfigPath is only valid with -DeploymentMode external."
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
    $podLabels = @{ "azure.workload.identity/use" = "true" }
    $controlPlaneNodeSelector = @{
        "kubernetes.io/os" = "linux"
        "kubernetes.azure.com/mode" = "system"
    }
    $mediaNodeSelectorSpot = @{
        "workload" = "video-encoding"
        "kubernetes.azure.com/scalesetpriority" = "spot"
        "kubernetes.io/os" = "linux"
    }
    $mediaNodeSelectorRegular = @{
        "workload" = "video-encoding"
        "kubernetes.azure.com/scalesetpriority" = "regular"
        "kubernetes.io/os" = "linux"
    }
    $mediaTolerationsSpot = @(@{
        key = "kubernetes.azure.com/scalesetpriority"
        operator = "Equal"
        value = "spot"
        effect = "NoSchedule"
    })
    $storageCsiDriver = "blob.csi.azure.com"
    $inputCsiVolumeAttributes = @{
        protocol = "fuse2"
        storageAccount = $inputStorageAccount
        containerName = $inputStorageContainer
        ClientID = $workloadClientId
        mountWithWorkloadIdentityToken = "true"
        mountOptions = "--allow-other --use-attr-cache=true --file-cache-timeout-in-seconds=300 --cancel-list-on-mount-seconds=10"
    }
    $outputCsiVolumeAttributes = @{
        protocol = "fuse2"
        storageAccount = $outputStorageAccount
        containerName = $outputStorageContainer
        ClientID = $workloadClientId
        mountWithWorkloadIdentityToken = "true"
        mountOptions = "--allow-other --use-attr-cache=true --file-cache-timeout-in-seconds=30 --disable-writeback-cache=true"
    }
    $triggerAuthentication = @{
        podIdentity = @{
            provider = "azure-workload"
            identityId = $workloadClientId
        }
    }
    $scalerMetadata = if ($MessageTransport -eq "storagequeue") {
        @{
            accountName = $outputStorageAccount
            queueName = "video-submitted"
            queueLength = "1"
            activationQueueLength = "0"
        }
    } else {
        @{
            namespace = $serviceBusNamespace.Split(".")[0]
            queueName = "video-submitted"
            messageCount = "1"
            activationMessageCount = "0"
        }
    }
    $scaler = @{
        mode = "keda"
        type = $(if ($MessageTransport -eq "storagequeue") { "azure-queue" } else { "azure-servicebus" })
        metadata = $scalerMetadata
        authenticationRef = "video-workload-identity"
    }
}

$ladderProfilesPath = Join-Path $root "deploy/ladder-profiles.json"
try {
    $ladderProfiles = Get-Content $ladderProfilesPath -Raw | ConvertFrom-Json
} catch {
    throw "Ladder profile configuration '$ladderProfilesPath' is not valid JSON: $($_.Exception.Message)"
}
if ($null -eq $ladderProfiles.rungs -or $null -eq $ladderProfiles.presets -or
    @($ladderProfiles.rungs.PSObject.Properties).Count -eq 0 -or
    @($ladderProfiles.presets.PSObject.Properties).Count -eq 0) {
    throw "Ladder profile configuration '$ladderProfilesPath' must contain non-empty 'rungs' and 'presets' objects."
}

$manifest = (Get-Content (Join-Path $root "deploy/k8s/video.yaml") -Raw) + `
    "`n---`n" + `
    (Get-Content (Join-Path $root "deploy/k8s/video-$MessageTransport.yaml") -Raw)
$ladderProfilesJson = (Get-Content $ladderProfilesPath) | ForEach-Object { "    $_" } | Join-String -Separator "`n"
$serviceBusShortName = if ([string]::IsNullOrWhiteSpace($serviceBusNamespace)) { "" } else { $serviceBusNamespace.Split(".")[0] }
$analysisDeployment = if ($MessageTransport -eq "storagequeue") { "video-analyzer-storagequeue" } else { "video-analysis-servicebus" }
$scalerMode = [string](Get-ConfigValue $scaler "mode" "none")
$triggerAuthenticationName = [string](Get-ConfigValue $scaler "authenticationRef" "video-workload-identity")

$replacements = @{
    "__WORKLOAD_CLIENT_ID__" = $workloadClientId
    "__SERVICE_BUS_NAMESPACE__" = $serviceBusNamespace
    "__SERVICE_BUS_NAMESPACE_SHORT__" = $serviceBusShortName
    "__INPUT_STORAGE_ACCOUNT__" = $inputStorageAccount
    "__INPUT_STORAGE_CONTAINER__" = $inputStorageContainer
    "__OUTPUT_STORAGE_ACCOUNT__" = $outputStorageAccount
    "__OUTPUT_STORAGE_CONTAINER__" = $outputStorageContainer
    "__IMAGE_REPOSITORY__" = $imageRepository
    "__IMAGE_TAG__" = $ImageTag
    "__DOTNET_MEDIA_IMAGE_TAG__" = $ImageTag
    "__RUST_MEDIA_IMAGE_TAG__" = $ImageTag
    "__MEDIA_RUNTIME__" = $MediaRuntime
    "__KUBERNETES_NAMESPACE__" = $KubernetesNamespace
    "__MAX_AUDIO_DURATION_SECONDS__" = [string]$MaxAudioDurationSeconds
    "__LADDER_PROFILES_JSON__" = $ladderProfilesJson
    "__SERVICE_ACCOUNT_NAME__" = $serviceAccountName
    "__SERVICE_ACCOUNT_ANNOTATIONS__" = (ConvertTo-YamlProperty "annotations" $serviceAccountAnnotations 2 -OmitWhenEmpty)
    "__POD_LABELS_8__" = ((ConvertTo-YamlLines $podLabels 8) -join "`n")
    "__CONTROL_PLANE_NODE_SELECTOR__" = (ConvertTo-YamlProperty "nodeSelector" $controlPlaneNodeSelector 6 -OmitWhenEmpty)
    "__CONTROL_PLANE_TOLERATIONS__" = (ConvertTo-YamlProperty "tolerations" $controlPlaneTolerations 6 -OmitWhenEmpty)
    "__STORAGE_CSI_DRIVER__" = $storageCsiDriver
    "__INPUT_CSI_VOLUME_ATTRIBUTES_14__" = ((ConvertTo-YamlLines $inputCsiVolumeAttributes 14) -join "`n")
    "__OUTPUT_CSI_VOLUME_ATTRIBUTES_14__" = ((ConvertTo-YamlLines $outputCsiVolumeAttributes 14) -join "`n")
    "__POD_LABELS_JSON__" = (ConvertTo-JsonConfig $podLabels).Replace("'", "''")
    "__MEDIA_NODE_SELECTOR_SPOT_JSON__" = (ConvertTo-JsonConfig $mediaNodeSelectorSpot).Replace("'", "''")
    "__MEDIA_NODE_SELECTOR_REGULAR_JSON__" = (ConvertTo-JsonConfig $mediaNodeSelectorRegular).Replace("'", "''")
    "__MEDIA_TOLERATIONS_SPOT_JSON__" = (ConvertTo-JsonConfig $mediaTolerationsSpot).Replace("'", "''")
    "__MEDIA_TOLERATIONS_REGULAR_JSON__" = (ConvertTo-JsonConfig $mediaTolerationsRegular).Replace("'", "''")
    "__INPUT_CSI_VOLUME_ATTRIBUTES_JSON__" = (ConvertTo-JsonConfig $inputCsiVolumeAttributes).Replace("'", "''")
    "__OUTPUT_CSI_VOLUME_ATTRIBUTES_JSON__" = (ConvertTo-JsonConfig $outputCsiVolumeAttributes).Replace("'", "''")
    "__TRIGGER_AUTHENTICATION_RESOURCE__" = (New-TriggerAuthenticationResource $KubernetesNamespace $triggerAuthenticationName $triggerAuthentication)
    "__SCALER_RESOURCE__" = (New-ScalerResource $KubernetesNamespace $analysisDeployment $scaler)
    "__ANALYZER_REPLICAS__" = $(if ($scalerMode -eq "keda") { "0" } else { "1" })
}
foreach ($replacement in $replacements.GetEnumerator()) {
    $manifest = $manifest.Replace($replacement.Key, [string]$replacement.Value)
}
if ($manifest -cmatch "__[A-Z0-9_]+__") {
    throw "Rendered Kubernetes manifest contains unresolved placeholder '$($Matches[0])'."
}

$renderedManifest = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RenderedManifestPath)
Set-Content -Path $renderedManifest -Value $manifest -Encoding UTF8
kubectl @kubectlContextArgs apply --filename $renderedManifest
Assert-NativeCommandSucceeded "Applying the Kubernetes manifest"

$completionDeployment = if ($MessageTransport -eq "storagequeue") { "video-completion-storagequeue" } else { "video-completion-servicebus" }
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
