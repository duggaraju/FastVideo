[CmdletBinding()]
param(
    [string] $ResourceGroup = "rg-spotvideo",
    [uri] $InputVideoUri = "https://spotvideoinsoudinndket2a.blob.core.windows.net/input/BigBuckBunny_1080p_10min.mp4",
    [ValidateRange(1, 86400)]
    [int] $SegmentDurationSeconds = 60,
    [ValidateSet("fixed-duration", "keyframe-boundary")]
    [string] $ParallelizationStrategy = "fixed-duration",
    [string] $AudioCodec = "copy",
    [Nullable[int]] $Crf,
    [Nullable[int]] $MaxVideoBitrateKbps,
    [bool] $UseSpot = $true,
    [switch] $CalculateVmaf,
    [ValidateRange(1, 1440)]
    [int] $TimeoutMinutes = 60,
    [ValidateRange(1, 300)]
    [int] $PollSeconds = 15
)

$ErrorActionPreference = "Stop"

function Assert-NativeCommandSucceeded([string] $Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

foreach ($command in @("az", "kubectl")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

$deploymentName = az deployment group list `
    --resource-group $ResourceGroup `
    --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp)[-1].name" `
    --output tsv
Assert-NativeCommandSucceeded "Finding the latest successful deployment"
if ([string]::IsNullOrWhiteSpace($deploymentName)) {
    throw "No successful deployment was found in resource group '$ResourceGroup'."
}

$deploymentJson = az deployment group show `
    --resource-group $ResourceGroup `
    --name $deploymentName `
    --query properties.outputs `
    --output json
Assert-NativeCommandSucceeded "Reading deployment outputs"
$deployment = $deploymentJson | ConvertFrom-Json

$inputPath = $InputVideoUri.AbsolutePath.TrimStart('/').Split('/', 2)
if ($InputVideoUri.Scheme -ne "https" -or $inputPath.Count -ne 2 -or
    -not $InputVideoUri.Host.EndsWith(".blob.core.windows.net", [StringComparison]::OrdinalIgnoreCase)) {
    throw "InputVideoUri must be an HTTPS Azure Blob URL containing a container and blob name."
}

$inputStorageAccount = $InputVideoUri.Host.Split('.')[0]
$inputContainer = $inputPath[0]
$inputBlobName = [uri]::UnescapeDataString($inputPath[1])
az storage blob show `
    --account-name $inputStorageAccount `
    --container-name $inputContainer `
    --name $inputBlobName `
    --auth-mode login `
    --only-show-errors `
    --output none
Assert-NativeCommandSucceeded "Verifying the input blob"

az aks get-credentials `
    --resource-group $ResourceGroup `
    --name $deployment.aksName.value `
    --overwrite-existing `
    --output none
Assert-NativeCommandSucceeded "Getting AKS credentials"

$jobId = "test-$(Get-Date -Format 'yyyyMMdd-HHmm')"
$serviceBusNamespace = $deployment.serviceBusNamespace.value
$outputStorageAccount = $deployment.outputStorageName.value
$outputContainer = $deployment.outputContainerName.value
$outputBlobName = "$jobId.mp4"
$outputVideoUri = "https://$outputStorageAccount.blob.core.windows.net/$outputContainer/$outputBlobName"
az storage container show `
    --account-name $outputStorageAccount `
    --name $outputContainer `
    --auth-mode login `
    --only-show-errors `
    --output none
Assert-NativeCommandSucceeded "Verifying access to the output container"

$payload = [ordered]@{
    jobId = $jobId
    inputVideoUri = $InputVideoUri.AbsoluteUri
    outputVideoUri = $outputVideoUri
    segmentDurationSeconds = $SegmentDurationSeconds
    parallelizationStrategy = $ParallelizationStrategy
    audioCodec = $AudioCodec
    useSpot = $UseSpot
    calculateVmaf = $CalculateVmaf.IsPresent
}
if ($null -ne $Crf) {
    if ($Crf -lt 0 -or $Crf -gt 63) { throw "Crf must be between 0 and 63." }
    $payload.crf = [int]$Crf
}
if ($null -ne $MaxVideoBitrateKbps) {
    if ($MaxVideoBitrateKbps -lt 64 -or $MaxVideoBitrateKbps -gt 100000) { throw "MaxVideoBitrateKbps must be between 64 and 100000." }
    $payload.maxVideoBitrateKbps = [int]$MaxVideoBitrateKbps
}
$payload = $payload | ConvertTo-Json -Compress
$payloadArgument = $payload.Replace('"', '\"')
$brokerProperties = [ordered]@{
    MessageId = $jobId
    CorrelationId = $jobId
} | ConvertTo-Json -Compress
$brokerPropertiesHeader = "BrokerProperties=$($brokerProperties.Replace('"', '\"'))"

Write-Host "Submitting $jobId to $serviceBusNamespace/video-submitted"
az rest `
    --method post `
    --url "https://$serviceBusNamespace/video-submitted/messages" `
    --resource "https://servicebus.azure.net" `
    --headers "Content-Type=application/json" $brokerPropertiesHeader `
    --body $payloadArgument `
    --output none
Assert-NativeCommandSucceeded "Submitting the video"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    $finalBlobExists = az storage blob exists `
        --account-name $outputStorageAccount `
        --container-name $outputContainer `
        --name $outputBlobName `
        --auth-mode login `
        --query exists `
        --output tsv `
        --only-show-errors
    Assert-NativeCommandSucceeded "Checking for the final output blob"

    if ($finalBlobExists -eq "true") {
        $finalBlob = az storage blob show `
            --account-name $outputStorageAccount `
            --container-name $outputContainer `
            --name $outputBlobName `
            --auth-mode login `
            --query "{name:name,size:properties.contentLength,lastModified:properties.lastModified}" `
            --output json `
            --only-show-errors | ConvertFrom-Json
        Assert-NativeCommandSucceeded "Reading the final output blob"
        if ($finalBlob.size -le 0) {
            throw "The final output blob exists but is empty."
        }

        $resultCount = az servicebus queue show `
            --resource-group $ResourceGroup `
            --namespace-name $serviceBusNamespace.Split('.')[0] `
            --name video-results `
            --query countDetails.activeMessageCount `
            --output tsv
        Assert-NativeCommandSucceeded "Reading the video-results queue status"

        Write-Host "Workflow completed for $jobId."
        Write-Host "Output: $outputVideoUri ($($finalBlob.size) bytes)"
        Write-Host "video-results active messages: $resultCount"
        Write-Host "Peek video-results in Service Bus Explorer and confirm jobId='$jobId', succeeded=true, terminalStage='stitch'."
        return
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Waiting for $outputBlobName"
    Start-Sleep -Seconds $PollSeconds
} while ((Get-Date) -lt $deadline)

Write-Host "The workflow did not complete within $TimeoutMinutes minutes. Current workloads:"
kubectl get scaledobjects,pods,jobs --namespace spotvideo
throw "Timed out waiting for '$outputVideoUri'."