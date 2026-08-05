[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroup,

    [string] $Location,

    [string] $Prefix = "spotvideo",
    [string] $ImageTag = "latest",
    [ValidateSet("btbn", "ubuntu")]
    [string] $FfmpegBuild = "btbn",
    [switch] $UseLocalDocker,
    [switch] $SkipInfrastructureDeployment
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Assert-NativeCommandSucceeded([string] $Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

if ($SkipInfrastructureDeployment) {
    $deploymentName = az deployment group list `
        --resource-group $ResourceGroup `
        --query "sort_by([?properties.provisioningState=='Succeeded' && properties.outputs.acrName != null], &properties.timestamp)[-1].name" `
        --output tsv
    Assert-NativeCommandSucceeded "Finding the latest successful SpotVideo infrastructure deployment"
    if ([string]::IsNullOrWhiteSpace($deploymentName)) {
        throw "No successful SpotVideo infrastructure deployment was found in resource group '$ResourceGroup'."
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
        --template-file (Join-Path $root "infra/main.bicep") `
        --parameters prefix=$Prefix `
        --query properties.outputs `
        --output json
    Assert-NativeCommandSucceeded "Deploying Azure resources; image builds and Kubernetes deployment were not started"
}
if ([string]::IsNullOrWhiteSpace($deploymentJson)) {
    throw "Azure resource deployment outputs are empty."
}
$deployment = $deploymentJson | ConvertFrom-Json

# Remove the write grant created by deployments predating input-storage read-only RBAC.
$legacyInputWriteGrantIds = @(az role assignment list `
    --assignee $deployment.workloadPrincipalId.value `
    --role "Storage Blob Data Contributor" `
    --scope $deployment.inputStorageId.value `
    --query "[].id" `
    --output tsv)
Assert-NativeCommandSucceeded "Checking for the legacy input-storage write role assignment"
if ($legacyInputWriteGrantIds.Count -gt 0) {
    az role assignment delete `
        --assignee $deployment.workloadPrincipalId.value `
        --role "Storage Blob Data Contributor" `
        --scope $deployment.inputStorageId.value
    Assert-NativeCommandSucceeded "Removing the legacy input-storage write role assignment"
}

$acrName = $deployment.acrName.value
$acrLoginServer = $deployment.acrLoginServer.value
$projects = @("Analysis", "Completion", "Encoder", "Stitcher")
foreach ($project in $projects) {
    $projectName = "Video$project"
    $imageName = "spotvideo-$($project.ToLowerInvariant())"
    $fullImage = "${acrLoginServer}/${imageName}:${ImageTag}"
    if ($UseLocalDocker) {
        docker build `
            --file (Join-Path $root "docker/Dockerfile") `
            --build-arg "PROJECT=$projectName" `
            --build-arg "APP_DLL=$projectName.dll" `
            --build-arg "FFMPEG_BUILD=$FfmpegBuild" `
            --tag $fullImage `
            $root
        Assert-NativeCommandSucceeded "Building $projectName image"
        az acr login --name $acrName
        Assert-NativeCommandSucceeded "Logging in to Azure Container Registry '$acrName'"
        docker push $fullImage
        Assert-NativeCommandSucceeded "Pushing $projectName image"
    } else {
        az acr build `
            --registry $acrName `
            --image "${imageName}:${ImageTag}" `
            --file (Join-Path $root "docker/Dockerfile") `
            --build-arg "PROJECT=$projectName" `
            --build-arg "APP_DLL=$projectName.dll" `
            --build-arg "FFMPEG_BUILD=$FfmpegBuild" `
            $root
        Assert-NativeCommandSucceeded "Building $projectName image in Azure Container Registry"
    }
}

az aks get-credentials `
    --resource-group $ResourceGroup `
    --name $deployment.aksName.value `
    --overwrite-existing
Assert-NativeCommandSucceeded "Getting AKS credentials"

$serviceBusNamespace = $deployment.serviceBusNamespace.value
$serviceBusShortName = $serviceBusNamespace.Split('.')[0]
$manifest = Get-Content (Join-Path $root "deploy/k8s/spotvideo.yaml") -Raw
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
}
foreach ($replacement in $replacements.GetEnumerator()) {
    $manifest = $manifest.Replace($replacement.Key, $replacement.Value)
}

$renderedManifest = Join-Path $root "deploy/rendered.yaml"
Set-Content -Path $renderedManifest -Value $manifest -Encoding UTF8
kubectl apply --filename $renderedManifest
Assert-NativeCommandSucceeded "Applying the Kubernetes manifest"

kubectl delete deployment/spotvideo-completion scaledobject/spotvideo-completion `
    --namespace spotvideo `
    --ignore-not-found
Assert-NativeCommandSucceeded "Removing the legacy completion processor"

kubectl rollout restart `
    --namespace spotvideo `
    deployment/spotvideo-analysis `
    deployment/spotvideo-job-watcher
Assert-NativeCommandSucceeded "Restarting SpotVideo deployments to use the rebuilt images"

$legacyQueue = az servicebus queue list `
    --resource-group $ResourceGroup `
    --namespace-name $serviceBusShortName `
    --query "[?name=='segment-completed'].name | [0]" `
    --output tsv
Assert-NativeCommandSucceeded "Checking for the legacy segment completion queue"
if (-not [string]::IsNullOrWhiteSpace($legacyQueue)) {
    az servicebus queue delete `
        --resource-group $ResourceGroup `
        --namespace-name $serviceBusShortName `
        --name segment-completed
    Assert-NativeCommandSucceeded "Removing the legacy segment completion queue"
}

$outputStorageId = az storage account show `
    --resource-group $ResourceGroup `
    --name $deployment.outputStorageName.value `
    --query id `
    --output tsv
Assert-NativeCommandSucceeded "Reading the output storage account ID"
$legacyTableRoleIds = @(az role assignment list `
    --assignee $deployment.workloadPrincipalId.value `
    --role "Storage Table Data Contributor" `
    --scope $outputStorageId `
    --query "[].id" `
    --output tsv)
Assert-NativeCommandSucceeded "Checking for the legacy table role assignment"
if ($legacyTableRoleIds.Count -gt 0) {
    az role assignment delete --ids $legacyTableRoleIds
    Assert-NativeCommandSucceeded "Removing the legacy table role assignment"
}

$legacyTableId = az resource list `
    --resource-group $ResourceGroup `
    --resource-type "Microsoft.Storage/storageAccounts/tableServices/tables" `
    --query "[?ends_with(id, '/tableServices/default/tables/encodingstate')].id | [0]" `
    --output tsv
Assert-NativeCommandSucceeded "Checking for the legacy encoding state table"
if (-not [string]::IsNullOrWhiteSpace($legacyTableId)) {
    az resource delete --ids $legacyTableId
    Assert-NativeCommandSucceeded "Removing the legacy encoding state table"
}

Write-Host "Deployed SpotVideo to $($deployment.aksName.value) with image tag $ImageTag"
Write-Host "Service Bus input queue: $serviceBusNamespace/video-submitted"
Write-Host "Input blob container: $($deployment.inputStorageServiceUri.value)/$($deployment.inputContainerName.value)"
Write-Host "Output blob container: $($deployment.outputStorageServiceUri.value)/$($deployment.outputContainerName.value)"