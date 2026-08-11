[CmdletBinding()]
param(
    [string] $ResourceGroup = "$([Environment]::UserName)-spotvideo",
    [uri] $InputVideoUri = "https://spotvideoinsoudinndket2a.blob.core.windows.net/input/BigBuckBunny_1080p_10min.mp4",
    [ValidateRange(1, 20)]
    [int] $Runs = 5,
    [bool] $UseSpot = $true,
    [ValidateSet("any", "amd64", "arm64")]
    [string] $Architecture = "any",
    [ValidateRange(0, 1000)]
    [decimal] $NodeHourlyPriceUsd = 0,
    [ValidateRange(1, 180)]
    [int] $TimeoutMinutes = 90,
    [string] $OutputPath
)

$ErrorActionPreference = "Stop"

function Assert-NativeCommandSucceeded([string] $Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-LabelValue([string] $Value) {
    $normalized = ($Value.ToLowerInvariant() -replace '[^a-z0-9.-]', '-').Trim('-', '.')
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $hashBytes = [Security.Cryptography.SHA256]::HashData($bytes)
    $hash = [Convert]::ToHexString($hashBytes).Substring(0, 10).ToLowerInvariant()
    $available = 52 - $hash.Length
    $prefix = $normalized.Substring(0, [Math]::Min($normalized.Length, $available)).TrimEnd('-', '.')
    return "$prefix-$hash"
}

function Measure-NodeActiveSeconds([object[]] $PodRuns) {
    $totalSeconds = 0.0
    foreach ($nodeGroup in @($PodRuns | Where-Object { $_.node -and $_.startedAt -and $_.finishedAt } | Group-Object node)) {
        $intervals = @($nodeGroup.Group | ForEach-Object {
            [pscustomobject]@{
                Start = [DateTimeOffset]$_.startedAt
                End = [DateTimeOffset]$_.finishedAt
            }
        } | Sort-Object Start)
        if ($intervals.Count -eq 0) {
            continue
        }

        $intervalStart = $intervals[0].Start
        $intervalEnd = $intervals[0].End
        foreach ($interval in $intervals | Select-Object -Skip 1) {
            if ($interval.Start -le $intervalEnd) {
                if ($interval.End -gt $intervalEnd) {
                    $intervalEnd = $interval.End
                }
            } else {
                $totalSeconds += ($intervalEnd - $intervalStart).TotalSeconds
                $intervalStart = $interval.Start
                $intervalEnd = $interval.End
            }
        }
        $totalSeconds += ($intervalEnd - $intervalStart).TotalSeconds
    }
    return $totalSeconds
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
$deployment = az deployment group show `
    --resource-group $ResourceGroup `
    --name $deploymentName `
    --query properties.outputs `
    --output json | ConvertFrom-Json
Assert-NativeCommandSucceeded "Reading deployment outputs"

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

$serviceBusNamespace = $deployment.serviceBusNamespace.value
$outputStorageAccount = $deployment.outputStorageName.value
$outputContainer = $deployment.outputContainerName.value
$priority = if ($UseSpot) { "spot" } else { "regular" }
$mode = "$priority-$Architecture"
$batchId = "bench-$mode-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "$batchId.json"
}

$results = @()
for ($run = 1; $run -le $Runs; $run++) {
    $jobId = "$batchId-$run"
    $labelValue = Get-LabelValue $jobId
    $encodeJobName = "encode-$labelValue"
    $stitchJobName = "stitch-$labelValue"
    $outputBlobName = "$jobId.mp4"
    $outputVideoUri = "https://$outputStorageAccount.blob.core.windows.net/$outputContainer/$outputBlobName"
    $payload = [ordered]@{
        jobId = $jobId
        inputVideoUri = $InputVideoUri.AbsoluteUri
        outputVideoUri = $outputVideoUri
        segmentDurationSeconds = 60
        parallelizationStrategy = "fixed-duration"
        audioCodec = "copy"
        useSpot = $UseSpot
        calculateVmaf = $false
    } | ConvertTo-Json -Compress
    $payloadArgument = $payload.Replace('"', '\"')
    $brokerProperties = [ordered]@{
        MessageId = $jobId
        CorrelationId = $jobId
    } | ConvertTo-Json -Compress
    $brokerPropertiesHeader = "BrokerProperties=$($brokerProperties.Replace('"', '\"'))"
    $messageHeaders = @("Content-Type=application/json", $brokerPropertiesHeader)
    if ($Architecture -ne "any") {
        $messageHeaders += "spotvideo-benchmark-architecture=$Architecture"
    }

    $submittedAt = [DateTimeOffset]::UtcNow
    Write-Host "[$run/$Runs] Submitting $jobId ($mode) at $submittedAt"
    az rest `
        --method post `
        --url "https://$serviceBusNamespace/video-submitted/messages" `
        --resource "https://servicebus.azure.net" `
        --headers $messageHeaders `
        --body $payloadArgument `
        --output none
    Assert-NativeCommandSucceeded "Submitting $jobId"

    kubectl wait --namespace spotvideo --for=create "job/$encodeJobName" --timeout="${TimeoutMinutes}m"
    Assert-NativeCommandSucceeded "Waiting for encode job creation"
    kubectl wait --namespace spotvideo --for=condition=complete "job/$encodeJobName" --timeout="${TimeoutMinutes}m"
    Assert-NativeCommandSucceeded "Waiting for encode job completion"

    $encodeJob = kubectl get job $encodeJobName --namespace spotvideo --output json | ConvertFrom-Json
    Assert-NativeCommandSucceeded "Reading encode job"
    $encoderPods = kubectl get pods --namespace spotvideo `
        --selector "app.kubernetes.io/name=spotvideo-encoder,spotvideo/job-id=$labelValue" `
        --output json | ConvertFrom-Json
    Assert-NativeCommandSucceeded "Reading encoder pods"

    kubectl wait --namespace spotvideo --for=create "job/$stitchJobName" --timeout="${TimeoutMinutes}m"
    Assert-NativeCommandSucceeded "Waiting for stitch job creation"
    kubectl wait --namespace spotvideo --for=condition=complete "job/$stitchJobName" --timeout="${TimeoutMinutes}m"
    Assert-NativeCommandSucceeded "Waiting for stitch job completion"
    $stitchJob = kubectl get job $stitchJobName --namespace spotvideo --output json | ConvertFrom-Json
    Assert-NativeCommandSucceeded "Reading stitch job"
    $stitchPods = kubectl get pods --namespace spotvideo `
        --selector "app.kubernetes.io/name=spotvideo-stitcher,spotvideo/job-id=$labelValue" `
        --output json | ConvertFrom-Json
    Assert-NativeCommandSucceeded "Reading stitch pods"

    $finalBlob = az storage blob show `
        --account-name $outputStorageAccount `
        --container-name $outputContainer `
        --name $outputBlobName `
        --auth-mode login `
        --only-show-errors `
        --output json | ConvertFrom-Json
    Assert-NativeCommandSucceeded "Reading final output blob"

    $encodeCreatedAt = [DateTimeOffset]$encodeJob.metadata.creationTimestamp
    $encodeStartedAt = [DateTimeOffset]$encodeJob.status.startTime
    $encodeCompletedAt = [DateTimeOffset]$encodeJob.status.completionTime
    $stitchCreatedAt = [DateTimeOffset]$stitchJob.metadata.creationTimestamp
    $stitchStartedAt = [DateTimeOffset]$stitchJob.status.startTime
    $stitchCompletedAt = [DateTimeOffset]$stitchJob.status.completionTime
    $allPods = @($encoderPods.items) + @($stitchPods.items)
    $nodeDetails = @{}
    foreach ($nodeName in @($allPods.spec.nodeName | Where-Object { $_ } | Sort-Object -Unique)) {
        $node = kubectl get node $nodeName --output json | ConvertFrom-Json
        Assert-NativeCommandSucceeded "Reading node $nodeName"
        $nodeDetails[$nodeName] = [pscustomobject]@{
            architecture = $node.metadata.labels.'kubernetes.io/arch'
            instanceType = $node.metadata.labels.'node.kubernetes.io/instance-type'
            nodePool = $node.metadata.labels.'kubernetes.azure.com/agentpool'
        }
    }
    $encoderPodRuns = @($encoderPods.items | ForEach-Object {
        $containerStatus = @($_.status.containerStatuses)[0]
        $terminated = $containerStatus.state.terminated
        $node = $nodeDetails[$_.spec.nodeName]
        [ordered]@{
            name = $_.metadata.name
            node = $_.spec.nodeName
            architecture = $node.architecture
            instanceType = $node.instanceType
            nodePool = $node.nodePool
            completionIndex = $_.metadata.annotations.'batch.kubernetes.io/job-completion-index'
            podStartedAt = $_.status.startTime
            startedAt = $terminated?.startedAt
            finishedAt = $terminated?.finishedAt
            durationSeconds = if ($terminated?.startedAt -and $terminated?.finishedAt) { (([DateTimeOffset]$terminated.finishedAt) - ([DateTimeOffset]$terminated.startedAt)).TotalSeconds } else { $null }
            exitCode = $terminated?.exitCode
        }
    })
    $stitchPodRuns = @($stitchPods.items | ForEach-Object {
        $containerStatus = @($_.status.containerStatuses)[0]
        $terminated = $containerStatus.state.terminated
        $node = $nodeDetails[$_.spec.nodeName]
        [ordered]@{
            name = $_.metadata.name
            node = $_.spec.nodeName
            architecture = $node.architecture
            instanceType = $node.instanceType
            nodePool = $node.nodePool
            startedAt = $terminated?.startedAt
            finishedAt = $terminated?.finishedAt
            durationSeconds = if ($terminated?.startedAt -and $terminated?.finishedAt) { (([DateTimeOffset]$terminated.finishedAt) - ([DateTimeOffset]$terminated.startedAt)).TotalSeconds } else { $null }
            exitCode = $terminated?.exitCode
        }
    })
    $workloadPodRuns = @($encoderPodRuns) + @($stitchPodRuns)
    if ($Architecture -ne "any") {
        $unexpectedArchitectures = @($workloadPodRuns | Where-Object { $_.architecture -ne $Architecture })
        if ($unexpectedArchitectures.Count -gt 0) {
            throw "One or more workload pods did not run on requested architecture '$Architecture'."
        }
    }
    $nodeActiveSeconds = Measure-NodeActiveSeconds $workloadPodRuns

    $result = [pscustomobject][ordered]@{
        run = $run
        jobId = $jobId
        mode = $mode
        requestedArchitecture = $Architecture
        submittedAt = $submittedAt
        encodeCreatedAt = $encodeCreatedAt
        encodeStartedAt = $encodeStartedAt
        encodeCompletedAt = $encodeCompletedAt
        stitchCreatedAt = $stitchCreatedAt
        stitchStartedAt = $stitchStartedAt
        stitchCompletedAt = $stitchCompletedAt
        analysisSeconds = ($encodeCreatedAt - $submittedAt).TotalSeconds
        encodeQueueAndRunSeconds = ($encodeCompletedAt - $encodeCreatedAt).TotalSeconds
        encodeRunSeconds = ($encodeCompletedAt - $encodeStartedAt).TotalSeconds
        stitchHandoffSeconds = ($stitchCreatedAt - $encodeCompletedAt).TotalSeconds
        stitchSeconds = ($stitchCompletedAt - $stitchCreatedAt).TotalSeconds
        totalSeconds = ($stitchCompletedAt - $submittedAt).TotalSeconds
        nodeActiveSeconds = $nodeActiveSeconds
        nodeHourlyPriceUsd = $NodeHourlyPriceUsd
        estimatedComputeUsd = if ($NodeHourlyPriceUsd -gt 0) { [Math]::Round($nodeActiveSeconds / 3600 * [double]$NodeHourlyPriceUsd, 6) } else { $null }
        outputBytes = $finalBlob.properties.contentLength
        encoderPods = $encoderPodRuns
        stitchPods = $stitchPodRuns
    }
    $results += $result
    $results | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding utf8
    Write-Host "[$run/$Runs] Completed $jobId in $([Math]::Round($result.totalSeconds, 1)) seconds"
}

$results | Format-Table run, mode, analysisSeconds, encodeQueueAndRunSeconds, stitchSeconds, totalSeconds, nodeActiveSeconds, estimatedComputeUsd
Write-Host "Results: $OutputPath"