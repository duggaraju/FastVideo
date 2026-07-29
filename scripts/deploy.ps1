[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroup,

    [Parameter(Mandatory)]
    [string] $Location,

    [string] $Prefix = "spotvideo",
    [string] $ImageTag = (Get-Date -Format "yyyyMMddHHmmss")
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

az group create --name $ResourceGroup --location $Location --output none
$deployment = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $root "infra/main.bicep") `
    --parameters prefix=$Prefix `
    --query properties.outputs `
    --output json | ConvertFrom-Json

$acrName = $deployment.acrName.value
$acrLoginServer = $deployment.acrLoginServer.value
$projects = @("Analysis", "Completion", "Encoder", "Stitcher")
foreach ($project in $projects) {
    $projectName = "SpotVideo.$project"
    $imageName = "spotvideo-$($project.ToLowerInvariant())"
    az acr build `
        --registry $acrName `
        --image "${imageName}:${ImageTag}" `
        --file (Join-Path $root "docker/Dockerfile") `
        --build-arg "PROJECT=$projectName" `
        --build-arg "APP_DLL=$projectName.dll" `
        $root
}

az aks get-credentials `
    --resource-group $ResourceGroup `
    --name $deployment.aksName.value `
    --overwrite-existing

$serviceBusNamespace = $deployment.serviceBusNamespace.value
$serviceBusShortName = $serviceBusNamespace.Split('.')[0]
$manifest = Get-Content (Join-Path $root "deploy/k8s/spotvideo.yaml") -Raw
$replacements = @{
    "__WORKLOAD_CLIENT_ID__" = $deployment.workloadClientId.value
    "__SERVICE_BUS_NAMESPACE__" = $serviceBusNamespace
    "__SERVICE_BUS_NAMESPACE_SHORT__" = $serviceBusShortName
    "__STORAGE_SERVICE_URI__" = $deployment.storageServiceUri.value
    "__TABLE_SERVICE_URI__" = $deployment.tableServiceUri.value
    "__ACR_LOGIN_SERVER__" = $acrLoginServer
    "__IMAGE_TAG__" = $ImageTag
}
foreach ($replacement in $replacements.GetEnumerator()) {
    $manifest = $manifest.Replace($replacement.Key, $replacement.Value)
}

$renderedManifest = Join-Path $root "deploy/rendered.yaml"
Set-Content -Path $renderedManifest -Value $manifest -Encoding utf8NoBOM
kubectl apply --filename $renderedManifest

Write-Host "Deployed SpotVideo to $($deployment.aksName.value) with image tag $ImageTag"
Write-Host "Service Bus input queue: $serviceBusNamespace/video-submitted"
Write-Host "Blob container: $($deployment.storageServiceUri.value)/videos"