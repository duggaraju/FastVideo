[CmdletBinding()]
param(
    [string] $ResourceGroup = "$([Environment]::UserName)-video",
    [uri] $InputVideoUri = "https://videoinsoudinndket2a.blob.core.windows.net/input/BigBuckBunny_1080p_10min.mp4",
    [ValidateRange(1, 86400)]
    [int] $SegmentDurationSeconds = 60,
    [ValidateSet("fixed-duration", "keyframe-boundary")]
    [string] $ParallelizationStrategy = "fixed-duration",
    [string] $AudioCodec = "copy",
    [ValidateSet("mp4", "cmaf", "both")]
    [string] $OutputType = "mp4",
    [Nullable[int]] $Crf,
    [Nullable[int]] $MaxVideoBitrateKbps,
    [bool] $UseSpot = $true,
    [switch] $CalculateVmaf,
    [ValidateSet("dotnet", "rust")]
    [string] $MediaRuntime = "rust",
    [ValidateSet("auto", "amd64", "arm64")]
    [string] $Architecture = "auto",
    [ValidateSet("auto", "storagequeue", "servicebus")]
    [string] $MessageTransport = "auto",
    [string] $KubernetesNamespace,
    [string] $JobId,
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

$deploymentQuery = if ($MessageTransport -eq "auto") {
    "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp)[-1].name"
} else {
    "sort_by([?properties.provisioningState=='Succeeded' && properties.outputs.messageTransport.value=='$MessageTransport'], &properties.timestamp)[-1].name"
}
$deploymentName = az deployment group list `
    --resource-group $ResourceGroup `
    --query $deploymentQuery `
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

$deployedTransport = [string]$deployment.messageTransport.value
if ([string]::IsNullOrWhiteSpace($deployedTransport)) {
    $deployedTransport = if (-not [string]::IsNullOrWhiteSpace([string]$deployment.outputQueueServiceUri.value)) {
        "storagequeue"
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$deployment.serviceBusNamespace.value)) {
        "servicebus"
    } else {
        throw "Deployment '$deploymentName' exposes neither outputQueueServiceUri nor serviceBusNamespace."
    }
}
if ($MessageTransport -eq "auto") {
    $MessageTransport = $deployedTransport
} elseif ($MessageTransport -ne $deployedTransport) {
    throw "Deployment '$deploymentName' uses '$deployedTransport', not '$MessageTransport'."
}
if ([string]::IsNullOrWhiteSpace($KubernetesNamespace)) {
    $KubernetesNamespace = [string]$deployment.kubernetesNamespace.value
    if ([string]::IsNullOrWhiteSpace($KubernetesNamespace)) {
        $KubernetesNamespace = "video-$MessageTransport"
    }
}

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

if ([string]::IsNullOrWhiteSpace($JobId)) {
    $vmafSuffix = if ($CalculateVmaf) { "vmaf" } else { "no-vmaf" }
    $JobId = "test-$MessageTransport-$vmafSuffix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
$jobId = $JobId
$outputStorageAccount = $deployment.outputStorageName.value
$outputContainer = $deployment.outputContainerName.value
$outputBlobName = "$jobId.mp4"
$outputBaseUri = "https://$outputStorageAccount.blob.core.windows.net/$outputContainer/$jobId"
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
    outputPath = $outputBaseUri
    segmentDurationSeconds = $SegmentDurationSeconds
    parallelizationStrategy = $ParallelizationStrategy
    audioCodec = $AudioCodec
    outputType = $OutputType
    useSpot = $UseSpot
    calculateVmaf = $CalculateVmaf.IsPresent
    mediaRuntime = $MediaRuntime
}
if ($null -ne $Crf) {
    if ($Crf -lt 0 -or $Crf -gt 63) { throw "Crf must be between 0 and 63." }
    $payload.crf = [int]$Crf
}
if ($null -ne $MaxVideoBitrateKbps) {
    if ($MaxVideoBitrateKbps -lt 64 -or $MaxVideoBitrateKbps -gt 100000) { throw "MaxVideoBitrateKbps must be between 64 and 100000." }
    $payload.maxVideoBitrateKbps = [int]$MaxVideoBitrateKbps
}
if ($Architecture -ne "auto") {
    $payload.architecture = $Architecture
}
$payload = $payload | ConvertTo-Json -Compress
if ($MessageTransport -eq "storagequeue") {
    $payloadArgument = $payload.Replace('"', '\"')
    Write-Host "Submitting $jobId to $outputStorageAccount/video-submitted with mediaRuntime=$MediaRuntime"
    az storage message put `
        --account-name $outputStorageAccount `
        --queue-name video-submitted `
        --content $payloadArgument `
        --auth-mode login `
        --only-show-errors `
        --output none
} else {
    $serviceBusNamespace = $deployment.serviceBusNamespace.value
    $payloadArgument = $payload.Replace('"', '\"')
    $brokerProperties = [ordered]@{
        MessageId = $jobId
        CorrelationId = $jobId
    } | ConvertTo-Json -Compress
    $brokerPropertiesHeader = "BrokerProperties=$($brokerProperties.Replace('"', '\"'))"

    Write-Host "Submitting $jobId to $serviceBusNamespace/video-submitted with mediaRuntime=$MediaRuntime"
    az rest `
        --method post `
        --url "https://$serviceBusNamespace/video-submitted/messages" `
        --resource "https://servicebus.azure.net" `
        --headers "Content-Type=application/json" $brokerPropertiesHeader `
        --body $payloadArgument `
        --output none
}
Assert-NativeCommandSucceeded "Submitting the video"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    $finalBlobExists = if ($OutputType -in @("mp4", "both")) {
        $mp4Exists = az storage blob exists `
            --account-name $outputStorageAccount `
            --container-name $outputContainer `
            --name $outputBlobName `
            --auth-mode login `
            --query exists `
            --output tsv `
            --only-show-errors
        Assert-NativeCommandSucceeded "Checking for the final MP4 blob"
        $mp4Exists -eq "true"
    } else {
        $true
    }

    $cmafBlobs = @()
    if ($OutputType -in @("cmaf", "both")) {
        $cmafPrefix = "$jobId-"
        $cmafBlobs = @(az storage blob list `
            --account-name $outputStorageAccount `
            --container-name $outputContainer `
            --prefix $cmafPrefix `
            --auth-mode login `
            --query "[].{name:name,size:properties.contentLength}" `
            --output json `
            --only-show-errors | ConvertFrom-Json)
        Assert-NativeCommandSucceeded "Checking for the CMAF package blobs"
        $requiredCmafNames = @(
            "$jobId-stream0.m3u8",
            "$jobId-stream1.m3u8",
            "$jobId-stream0.cmaf",
            "$jobId-stream1.cmaf"
        )
        $manifestBlobs = @(az storage blob list `
            --account-name $outputStorageAccount `
            --container-name $outputContainer `
            --prefix $jobId `
            --auth-mode login `
            --query "[?name=='$jobId.mpd' || name=='$jobId.m3u8'].{name:name,size:properties.contentLength}" `
            --output json `
            --only-show-errors | ConvertFrom-Json)
        $cmafBlobs += $manifestBlobs
        $requiredCmafNames += @("$jobId.mpd", "$jobId.m3u8")
        $cmafBlobsByName = @{}
        foreach ($blob in $cmafBlobs) {
            $cmafBlobsByName[[string]$blob.name] = [long]$blob.size
        }
        $cmafComplete = @($requiredCmafNames | Where-Object {
            -not $cmafBlobsByName.ContainsKey($_) -or $cmafBlobsByName[$_] -le 0
        }).Count -eq 0
    } else {
        $cmafComplete = $true
    }

    if ($finalBlobExists -and $cmafComplete) {
        if ($OutputType -in @("mp4", "both")) {
            $finalBlob = az storage blob show `
                --account-name $outputStorageAccount `
                --container-name $outputContainer `
                --name $outputBlobName `
                --auth-mode login `
                --query "{name:name,size:properties.contentLength,lastModified:properties.lastModified}" `
                --output json `
                --only-show-errors | ConvertFrom-Json
            Assert-NativeCommandSucceeded "Reading the final MP4 blob"
            if ($finalBlob.size -le 0) {
                throw "The final MP4 blob exists but is empty."
            }
        }

        if ($CalculateVmaf) {
            $vmafBlobName = [IO.Path]::ChangeExtension($outputBlobName, ".vmaf.json")
            $vmafBlob = az storage blob show `
                --account-name $outputStorageAccount `
                --container-name $outputContainer `
                --name $vmafBlobName `
                --auth-mode login `
                --query "{name:name,size:properties.contentLength}" `
                --output json `
                --only-show-errors | ConvertFrom-Json
            Assert-NativeCommandSucceeded "Reading the final VMAF result"
            if ($vmafBlob.size -le 0) {
                throw "The final VMAF result exists but is empty."
            }
            Write-Host "VMAF result: https://$outputStorageAccount.blob.core.windows.net/$outputContainer/$vmafBlobName ($($vmafBlob.size) bytes)"
        }

        if ($MessageTransport -eq "storagequeue") {
            $resultMessages = az storage message peek `
                --account-name $outputStorageAccount `
                --queue-name video-results `
                --auth-mode login `
                --num-messages 32 `
                --output json | ConvertFrom-Json
            $resultCount = @($resultMessages).Count
        } else {
            $resultCount = az servicebus queue show `
                --resource-group $ResourceGroup `
                --namespace-name $serviceBusNamespace.Split('.')[0] `
                --name video-results `
                --query countDetails.activeMessageCount `
                --output tsv
        }
        Assert-NativeCommandSucceeded "Reading the video-results queue status"

        Write-Host "Workflow completed for $jobId (transport=$MessageTransport, outputType=$OutputType, calculateVmaf=$($CalculateVmaf.IsPresent))."
        if ($OutputType -in @("mp4", "both")) {
            Write-Host "MP4 output: $outputBaseUri.mp4 ($($finalBlob.size) bytes)"
        }
        if ($OutputType -in @("cmaf", "both")) {
            Write-Host "CMAF package:"
            $cmafBlobs | Sort-Object name | ForEach-Object {
                Write-Host "  https://$outputStorageAccount.blob.core.windows.net/$outputContainer/$($_.name) ($($_.size) bytes)"
            }
        }
        Write-Host "video-results active messages: $resultCount"
        if ($MessageTransport -eq "storagequeue") {
            Write-Host "Peek video-results in Storage Explorer or az storage message peek and confirm jobId='$jobId', succeeded=true, terminalStage='stitch'."
        } else {
            Write-Host "Peek video-results in Service Bus Explorer and confirm jobId='$jobId', succeeded=true, terminalStage='stitch'."
        }
        return
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Waiting for outputType=$OutputType artifacts for $jobId"
    Start-Sleep -Seconds $PollSeconds
} while ((Get-Date) -lt $deadline)

Write-Host "The workflow did not complete within $TimeoutMinutes minutes. Current workloads:"
kubectl get scaledobjects,pods,jobs --namespace $KubernetesNamespace
throw "Timed out waiting for artifacts at '$outputBaseUri'."