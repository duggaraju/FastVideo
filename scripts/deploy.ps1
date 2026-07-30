[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroup,

    [Parameter(Mandatory)]
    [string] $Location,

    [string] $Prefix = "spotvideo",
    [string] $ImageTag = "latest",
    [switch] $UseLocalDocker
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
    $projectName = "Video$project"
    $imageName = "spotvideo-$($project.ToLowerInvariant())"
    $fullImage = "${acrLoginServer}/${imageName}:${ImageTag}"
    if ($UseLocalDocker) {
        docker build `
            --file (Join-Path $root "docker/Dockerfile") `
            --build-arg "PROJECT=$projectName" `
            --build-arg "APP_DLL=$projectName.dll" `
            --tag $fullImage `
            $root
        az acr login --name $acrName
        docker push $fullImage
    } else {
        az acr build `
            --registry $acrName `
            --image "${imageName}:${ImageTag}" `
            --file (Join-Path $root "docker/Dockerfile") `
            --build-arg "PROJECT=$projectName" `
            --build-arg "APP_DLL=$projectName.dll" `
            $root
    }
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
    "__TABLE_SERVICE_URI__" = $deployment.tableServiceUri.value
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

Write-Host "Deployed SpotVideo to $($deployment.aksName.value) with image tag $ImageTag"
Write-Host "Service Bus input queue: $serviceBusNamespace/video-submitted"
Write-Host "Input blob container: $($deployment.inputStorageServiceUri.value)/$($deployment.inputContainerName.value)"
Write-Host "Output blob container: $($deployment.outputStorageServiceUri.value)/$($deployment.outputContainerName.value)"