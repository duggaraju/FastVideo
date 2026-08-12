[CmdletBinding()]
param(
    [string] $ResourceGroup = "$([Environment]::UserName)-video",

    [string] $Location,

    [string] $Prefix = "video",
    [string] $ImageTag = "latest",
    [string] $DotNetMediaImageTag,
    [string] $RustMediaImageTag,
    [ValidateSet("dotnet", "rust")]
    [string] $MediaRuntime = "rust",
    [ValidateSet("storagequeue", "servicebus")]
    [string] $MessageTransport = "storagequeue",
    [string] $KubernetesNamespace,
    [ValidateSet("btbn", "custom")]
    [string] $FfmpegBuild = "btbn",
    [string] $FfmpegVersion = "9.0",
    [string] $Platforms = "linux/amd64,linux/arm64",
    [string] $ControlPlanePlatforms = "linux/amd64",
    [switch] $UseLocalDocker = $true,
    [switch] $SkipInfrastructureDeployment
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($KubernetesNamespace)) {
    $KubernetesNamespace = "video-$MessageTransport"
}

function Assert-NativeCommandSucceeded([string] $Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
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

$acrName = $deployment.acrName.value
$acrLoginServer = $deployment.acrLoginServer.value
if ([string]::IsNullOrWhiteSpace($DotNetMediaImageTag)) {
    $DotNetMediaImageTag = $ImageTag
}
if ([string]::IsNullOrWhiteSpace($RustMediaImageTag)) {
    $RustMediaImageTag = $ImageTag
}
$projects = @("Analysis", "Completion", "Encoder", "Stitcher")
foreach ($project in $projects) {
    $projectName = "Video$project"
    $isControlPlaneWorker = $project -in @("Analysis", "Completion")
    $imageName = if ($isControlPlaneWorker) {
        "video-$($project.ToLowerInvariant())-$MessageTransport"
    } else {
        "video-$($project.ToLowerInvariant())-$MediaRuntime"
    }
    $fullImage = "${acrLoginServer}/${imageName}:${ImageTag}"
    $projectPlatforms = if ($isControlPlaneWorker) { $ControlPlanePlatforms } else { $Platforms }
    $isRustWorker = ($isControlPlaneWorker -and $MessageTransport -eq "storagequeue") -or `
        (-not $isControlPlaneWorker -and $MediaRuntime -eq "rust")
    $dockerfile = Join-Path $root $(if ($isRustWorker) { "rust/Dockerfile" } else { "docker/Dockerfile" })
    $buildArguments = if ($isRustWorker) {
        $binary = switch ($project) {
            "Analysis" { "analyzer" }
            "Completion" { "completion" }
            default { $project.ToLowerInvariant() }
        }
        @(
            "--build-arg", "BINARY=$binary",
            "--build-arg", "FFMPEG_BUILD=$FfmpegBuild",
            "--build-arg", "FFMPEG_VERSION=$FfmpegVersion"
        )
    } else {
        @(
            "--build-arg", "PROJECT=$projectName",
            "--build-arg", "APP_DLL=$projectName.dll",
            "--build-arg", "FFMPEG_BUILD=$FfmpegBuild",
            "--build-arg", "FFMPEG_VERSION=$FfmpegVersion"
        )
    }
    if ($isRustWorker -and $project -in @("Analysis", "Completion")) {
        $buildArguments += @("--build-arg", "CARGO_FEATURES=--features=control-plane")
    }
    if ($UseLocalDocker) {
        az acr login --name $acrName
        Assert-NativeCommandSucceeded "Logging in to Azure Container Registry '$acrName'"
        if ($projectPlatforms.Contains(',')) {
            docker buildx build `
            --platform $projectPlatforms `
                --provenance=false `
                --sbom=false `
                --file $dockerfile `
                @buildArguments `
                --tag $fullImage `
                --push `
                $root
            Assert-NativeCommandSucceeded "Building and pushing multi-platform $projectName image"
        } else {
            docker build `
                --platform $projectPlatforms `
                --provenance=false `
                --sbom=false `
                --file $dockerfile `
                @buildArguments `
                --tag $fullImage `
                $root
            Assert-NativeCommandSucceeded "Building $projectName image"
            docker push $fullImage
            Assert-NativeCommandSucceeded "Pushing $projectName image"
        }
    } else {
        $platformList = @($projectPlatforms.Split(',', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() })
        $platformImages = @()
        foreach ($platform in $platformList) {
            $platformSuffix = $platform.Replace('linux/', '')
            $platformImage = "${imageName}:${ImageTag}-${platformSuffix}"
            az acr build `
                --registry $acrName `
                --image $platformImage `
                --platform $platform `
                --file $dockerfile `
                --build-arg "TARGETARCH=$platformSuffix" `
                @buildArguments `
                $root
            Assert-NativeCommandSucceeded "Building $projectName image for $platform in Azure Container Registry"
            $platformImages += "${acrLoginServer}/${platformImage}"
        }
        if ($platformImages.Count -gt 1) {
            az acr login --name $acrName
            Assert-NativeCommandSucceeded "Logging in to Azure Container Registry '$acrName'"
            docker buildx imagetools create --tag $fullImage @platformImages
            Assert-NativeCommandSucceeded "Creating multi-platform manifest for $projectName"
        } else {
            az acr import `
                --name $acrName `
                --source $platformImages[0] `
                --image "${imageName}:${ImageTag}" `
                --force
            Assert-NativeCommandSucceeded "Tagging $projectName image"
        }
    }
}

az aks get-credentials `
    --resource-group $ResourceGroup `
    --name $deployment.aksName.value `
    --overwrite-existing
Assert-NativeCommandSucceeded "Getting AKS credentials"

$serviceBusNamespace = [string]$deployment.serviceBusNamespace.value
$serviceBusShortName = if ([string]::IsNullOrWhiteSpace($serviceBusNamespace)) { "" } else { $serviceBusNamespace.Split('.')[0] }
$manifest = (Get-Content (Join-Path $root "deploy/k8s/video.yaml") -Raw) + `
    "`n---`n" + `
    (Get-Content (Join-Path $root "deploy/k8s/video-$MessageTransport.yaml") -Raw)
$replacements = @{
    "__WORKLOAD_CLIENT_ID__" = $deployment.workloadClientId.value
    "__SERVICE_BUS_NAMESPACE__" = $serviceBusNamespace
    "__SERVICE_BUS_NAMESPACE_SHORT__" = $serviceBusShortName
    "__INPUT_STORAGE_ACCOUNT__" = $deployment.inputStorageName.value
    "__INPUT_STORAGE_CONTAINER__" = $deployment.inputContainerName.value
    "__OUTPUT_STORAGE_ACCOUNT__" = $deployment.outputStorageName.value
    "__OUTPUT_STORAGE_CONTAINER__" = $deployment.outputContainerName.value
    "__ACR_LOGIN_SERVER__" = $acrLoginServer
    "__IMAGE_TAG__" = $ImageTag
    "__DOTNET_MEDIA_IMAGE_TAG__" = $DotNetMediaImageTag
    "__RUST_MEDIA_IMAGE_TAG__" = $RustMediaImageTag
    "__MEDIA_RUNTIME__" = $MediaRuntime
    "__KUBERNETES_NAMESPACE__" = $KubernetesNamespace
}
foreach ($replacement in $replacements.GetEnumerator()) {
    $manifest = $manifest.Replace($replacement.Key, $replacement.Value)
}

$renderedManifest = Join-Path $root "deploy/rendered.yaml"
Set-Content -Path $renderedManifest -Value $manifest -Encoding UTF8
kubectl apply --filename $renderedManifest
Assert-NativeCommandSucceeded "Applying the Kubernetes manifest"

$analysisDeployment = if ($MessageTransport -eq "storagequeue") { "video-analyzer-storagequeue" } else { "video-analysis-servicebus" }
$completionDeployment = if ($MessageTransport -eq "storagequeue") { "video-completion-storagequeue" } else { "video-completion-servicebus" }
$unpausePatch = '{"metadata":{"annotations":{"autoscaling.keda.sh/paused":null,"autoscaling.keda.sh/paused-replicas":null}}}'
kubectl patch "scaledobject/$analysisDeployment" --namespace $KubernetesNamespace --type merge --patch $unpausePatch
Assert-NativeCommandSucceeded "Unpausing selected ScaledObject '$analysisDeployment'"

kubectl rollout restart `
    --namespace $KubernetesNamespace `
    "deployment/$analysisDeployment" `
    "deployment/$completionDeployment"
Assert-NativeCommandSucceeded "Restarting video deployments to use the rebuilt images"

Write-Host "Deployed video pipeline to $($deployment.aksName.value) in namespace $KubernetesNamespace with $MessageTransport control plane, $MediaRuntime media workers, and image tag $ImageTag"
if ($MessageTransport -eq "storagequeue") {
    Write-Host "Storage Queue input queue: https://$($deployment.outputStorageName.value).queue.core.windows.net/video-submitted"
    Write-Host "Storage Queue result queue: https://$($deployment.outputStorageName.value).queue.core.windows.net/video-results"
} else {
    Write-Host "Service Bus input queue: $serviceBusNamespace/video-submitted"
    Write-Host "Service Bus result queue: $serviceBusNamespace/video-results"
}
Write-Host "Input blob container: $($deployment.inputStorageServiceUri.value)/$($deployment.inputContainerName.value)"
Write-Host "Output blob container: $($deployment.outputStorageServiceUri.value)/$($deployment.outputContainerName.value)"