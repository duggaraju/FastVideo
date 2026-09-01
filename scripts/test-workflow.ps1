#!/usr/bin/env pwsh

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
    [ValidateSet("max4k", "max2160p", "max1440p", "max1080p", "max720p", "max480p", "max360p")]
    [string] $Preset,
    [Nullable[int]] $Crf,
    [Nullable[int]] $MaxVideoBitrateKbps,
    [ValidateSet("interruptible", "regular")]
    [string] $CapacityClass = "interruptible",
    [switch] $CalculateVmaf,
    [ValidateSet("dotnet", "rust")]
    [string] $MediaRuntime = "rust",
    [ValidateSet("auto", "amd64", "arm64")]
    [string] $Architecture = "auto",
    [ValidateSet("auto", "storagequeue", "servicebus")]
    [string] $MessageTransport = "auto",
    [string] $KubernetesNamespace,
    [uri] $OutputVideoUri ="https://videooutsoudinndket2a.blob.core.windows.net/videos",
    [bool] $UseJobIdAsPrefix = $true,
    [string] $JobId,
    [ValidateRange(1, 1440)]
    [int] $TimeoutMinutes = 60,
    [ValidateRange(1, 300)]
    [int] $PollSeconds = 15
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or later is required."
}

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

$aksName = [string]$deployment.aksName.value
$currentCluster = kubectl config view --minify --output "jsonpath={.contexts[0].context.cluster}" 2>$null
$kubectlReady = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentCluster) -and
    (kubectl get namespace $KubernetesNamespace --request-timeout=10s --output name 2>$null)
if (-not $kubectlReady) {
    az aks get-credentials `
        --resource-group $ResourceGroup `
        --name $aksName `
        --overwrite-existing `
        --output none
    Assert-NativeCommandSucceeded "Getting AKS credentials"
} else {
    Write-Host "Using the current working kubectl context for AKS cluster '$aksName'."
}

if ([string]::IsNullOrWhiteSpace($JobId)) {
    $vmafSuffix = if ($CalculateVmaf) { "vmaf" } else { "no-vmaf" }
    $JobId = "test-$MessageTransport-$vmafSuffix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
$jobId = $JobId
$outputStorageAccount = $deployment.outputStorageName.value
$outputContainer = $deployment.outputContainerName.value
$configuredOutputUri = if ($null -eq $OutputVideoUri) {
    [uri]"https://$outputStorageAccount.blob.core.windows.net/$outputContainer"
} else {
    $OutputVideoUri
}
$outputUriPath = $configuredOutputUri.AbsolutePath.Trim('/').Split('/', 2)
if ($configuredOutputUri.Scheme -ne "https" -or
    -not $configuredOutputUri.Host.Equals("$outputStorageAccount.blob.core.windows.net", [StringComparison]::OrdinalIgnoreCase) -or
    $outputUriPath.Count -lt 1 -or
    -not $outputUriPath[0].Equals($outputContainer, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputVideoUri must identify the deployed HTTPS output container 'https://$outputStorageAccount.blob.core.windows.net/$outputContainer', optionally followed by a blob prefix."
}
$configuredOutputPrefix = if ($outputUriPath.Count -eq 2) {
    [uri]::UnescapeDataString($outputUriPath[1]).Trim('/')
} else {
    ""
}
$outputFileBaseName = [IO.Path]::GetFileNameWithoutExtension($inputBlobName)
if ([string]::IsNullOrWhiteSpace($outputFileBaseName)) {
    throw "InputVideoUri must identify a file with a non-empty basename."
}
$outputPathParts = @(
    $configuredOutputPrefix
    $(if ($UseJobIdAsPrefix) { $jobId })
    $outputFileBaseName
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$artifactBaseNameWithoutProfile = $outputPathParts -join '/'
$outputBaseUri = "https://$outputStorageAccount.blob.core.windows.net/$outputContainer/$artifactBaseNameWithoutProfile"
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
    calculateVmaf = $CalculateVmaf.IsPresent
    mediaRuntime = $MediaRuntime
}
if (-not [string]::IsNullOrWhiteSpace($CapacityClass)) {
    $payload.capacityClass = $CapacityClass
}
if ($null -ne $Crf) {
    if ($Crf -lt 0 -or $Crf -gt 63) { throw "Crf must be between 0 and 63." }
    $payload.crf = [int]$Crf
}
if (-not [string]::IsNullOrWhiteSpace($Preset)) {
    $payload.preset = $Preset
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
    Write-Host "Submitting $jobId to $outputStorageAccount/video-submitted with mediaRuntime=$MediaRuntime"
    # az.cmd uses legacy native argument parsing on Windows, which otherwise strips
    # JSON quotes and produces an invalid payload such as {jobId:value}.
    $queuePayload = if ($IsWindows) { $payload.Replace('"', '\"') } else { $payload }
    az storage message put `
        --account-name $outputStorageAccount `
        --queue-name video-submitted `
        --content $queuePayload `
        --auth-mode login `
        --only-show-errors `
        --output none
} else {
    $serviceBusNamespace = $deployment.serviceBusNamespace.value
    $brokerProperties = [ordered]@{
        MessageId = $jobId
        CorrelationId = $jobId
    } | ConvertTo-Json -Compress
    $brokerPropertiesHeader = "BrokerProperties=$brokerProperties"

    Write-Host "Submitting $jobId to $serviceBusNamespace/video-submitted with mediaRuntime=$MediaRuntime"
    az rest `
        --method post `
        --url "https://$serviceBusNamespace/video-submitted/messages" `
        --resource "https://servicebus.azure.net" `
        --headers "Content-Type=application/json" $brokerPropertiesHeader `
        --body $payload `
        --output none
}
Assert-NativeCommandSucceeded "Submitting the video"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$manifestBlobName = "$jobId/manifest.json"
$manifestTempPath = Join-Path ([IO.Path]::GetTempPath()) "$jobId-manifest.json"
try {
    do {
        $manifestExists = az storage blob exists `
            --account-name $outputStorageAccount `
            --container-name $outputContainer `
            --name $manifestBlobName `
            --auth-mode login `
            --query exists `
            --output tsv `
            --only-show-errors
        Assert-NativeCommandSucceeded "Checking for the analysis manifest"
        if ($manifestExists -eq "true") { break }
        if ((Get-Date) -ge $deadline) {
            throw "Timed out waiting for analysis manifest '$manifestBlobName'."
        }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)

    az storage blob download `
        --account-name $outputStorageAccount `
        --container-name $outputContainer `
        --name $manifestBlobName `
        --file $manifestTempPath `
        --auth-mode login `
        --overwrite `
        --only-show-errors `
        --output none
    Assert-NativeCommandSucceeded "Downloading the analysis manifest"
    $manifest = Get-Content -Raw $manifestTempPath | ConvertFrom-Json
} finally {
    Remove-Item $manifestTempPath -Force -ErrorAction SilentlyContinue
}

$profileName = if ([string]::IsNullOrWhiteSpace($Preset)) {
    $null
} else {
    [string]$manifest.encodingProfiles[0].name
    if ([string]::IsNullOrWhiteSpace($manifest.encodingProfiles[0].name)) {
        throw "Analysis manifest '$manifestBlobName' contains no encoding profile."
    }
}
$artifactBaseName = if ($null -eq $profileName) {
    $artifactBaseNameWithoutProfile
} else {
    "$artifactBaseNameWithoutProfile-$profileName"
}
$outputBlobName = "$artifactBaseName.mp4"
Write-Host "Analysis selected highest rendition: $(if ($null -eq $profileName) { 'source resolution' } else { $profileName })"

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
        $cmafPrefix = "$artifactBaseName-"
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
            "$artifactBaseName-stream0.m3u8",
            "$artifactBaseName-stream1.m3u8",
            "$artifactBaseName-stream0.cmaf",
            "$artifactBaseName-stream1.cmaf"
        )
        $manifestBlobs = @(az storage blob list `
            --account-name $outputStorageAccount `
            --container-name $outputContainer `
            --prefix $artifactBaseName `
            --auth-mode login `
            --query "[?name=='$artifactBaseName.mpd' || name=='$artifactBaseName.m3u8'].{name:name,size:properties.contentLength}" `
            --output json `
            --only-show-errors | ConvertFrom-Json)
        $cmafBlobs += $manifestBlobs
        $requiredCmafNames += @("$artifactBaseName.mpd", "$artifactBaseName.m3u8")
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

        Write-Host "Workflow completed for $jobId (transport=$MessageTransport, preset=$Preset, outputType=$OutputType, calculateVmaf=$($CalculateVmaf.IsPresent))."
        if ($OutputType -in @("mp4", "both")) {
            Write-Host "MP4 output: https://$outputStorageAccount.blob.core.windows.net/$outputContainer/$outputBlobName ($($finalBlob.size) bytes)"
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
throw "Timed out waiting for artifacts with base name '$artifactBaseName' at '$outputBaseUri'."