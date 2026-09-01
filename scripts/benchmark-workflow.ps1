#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [string] $ResourceGroup = "$([Environment]::UserName)-video",
    [uri] $InputVideoUri = "https://videoinsoudinndket2a.blob.core.windows.net/input/BigBuckBunny_1080p_10min.mp4",
    [ValidateRange(1, 20)]
    [int] $Runs = 5,
    [ValidateSet("interruptible", "regular")]
    [string] $CapacityClass = "interruptible",
    [ValidateSet("dotnet", "rust")]
    [string] $MediaRuntime = "rust",
    [ValidateSet("auto", "storagequeue", "servicebus")]
    [string] $MessageTransport = "auto",
    [string] $KubernetesNamespace,
    [ValidateSet("any", "amd64", "arm64")]
    [string] $Architecture = "any",
    [bool] $CalculateVmaf = $false,
    [ValidateRange(0, 1000)]
    [decimal] $NodeHourlyPriceUsd = 0,
    [ValidateRange(1, 180)]
    [int] $TimeoutMinutes = 90,
    [string] $BatchId,
    [string] $OutputPath
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
$deployment = az deployment group show `
    --resource-group $ResourceGroup `
    --name $deploymentName `
    --query properties.outputs `
    --output json | ConvertFrom-Json
Assert-NativeCommandSucceeded "Reading deployment outputs"

$deployedTransport = [string]$deployment.messageTransport.value
if ([string]::IsNullOrWhiteSpace($deployedTransport)) {
    $deployedTransport = if (-not [string]::IsNullOrWhiteSpace([string]$deployment.outputQueueServiceUri.value)) {
        "storagequeue"
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$deployment.serviceBusNamespace.value)) {
        "servicebus"
    } else {
        throw "Deployment '$deploymentName' does not identify a supported message transport."
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

$outputStorageAccount = $deployment.outputStorageName.value
$outputContainer = $deployment.outputContainerName.value
$capacityMode = if ([string]::IsNullOrWhiteSpace($CapacityClass)) { "unconstrained" } else { $CapacityClass }
$mode = "$MediaRuntime-$capacityMode-$Architecture"
if ([string]::IsNullOrWhiteSpace($BatchId)) {
    $BatchId = "bench-$mode-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "$BatchId.json"
}

$results = @()
for ($run = 1; $run -le $Runs; $run++) {
    $jobId = "$BatchId-$run"
    $labelValue = Get-LabelValue $jobId
    $encodeJobName = "encode-$labelValue"
    $stitchJobName = "stitch-$labelValue"
    $outputBlobName = "$jobId.mp4"
    $outputBaseUri = "https://$outputStorageAccount.blob.core.windows.net/$outputContainer/$jobId"
    $payload = [ordered]@{
        jobId = $jobId
        inputVideoUri = $InputVideoUri.AbsoluteUri
        outputPath = $outputBaseUri
        segmentDurationSeconds = 60
        parallelizationStrategy = "fixed-duration"
        audioCodec = "copy"
        calculateVmaf = $CalculateVmaf
        mediaRuntime = $MediaRuntime
    }
    if (-not [string]::IsNullOrWhiteSpace($CapacityClass)) {
        $payload.capacityClass = $CapacityClass
    }
    if ($Architecture -ne "any") {
        $payload.architecture = $Architecture
    }
    $payload = $payload | ConvertTo-Json -Compress

    $submittedAt = [DateTimeOffset]::UtcNow
    Write-Host "[$run/$Runs] Submitting $jobId ($mode) at $submittedAt"
    if ($MessageTransport -eq "storagequeue") {
        az storage message put `
            --account-name $outputStorageAccount `
            --queue-name video-submitted `
            --content $payload `
            --auth-mode login `
            --only-show-errors `
            --output none
    } else {
        $serviceBusNamespace = [string]$deployment.serviceBusNamespace.value
        $brokerProperties = [ordered]@{
            MessageId = $jobId
            CorrelationId = $jobId
        } | ConvertTo-Json -Compress
        $messageHeaders = @(
            "Content-Type=application/json",
            "BrokerProperties=$($brokerProperties.Replace('"', '\"'))"
        )
        az rest `
            --method post `
            --url "https://$serviceBusNamespace/video-submitted/messages" `
            --resource "https://servicebus.azure.net" `
            --headers $messageHeaders `
            --body $payload `
            --output none
    }
    Assert-NativeCommandSucceeded "Submitting $jobId"

    kubectl wait --namespace $KubernetesNamespace --for=create "job/$encodeJobName" --timeout="${TimeoutMinutes}m"
    Assert-NativeCommandSucceeded "Waiting for encode job creation"
    kubectl wait --namespace $KubernetesNamespace --for=condition=complete "job/$encodeJobName" --timeout="${TimeoutMinutes}m"
    Assert-NativeCommandSucceeded "Waiting for encode job completion"

    $encodeJob = kubectl get job $encodeJobName --namespace $KubernetesNamespace --output json | ConvertFrom-Json
    Assert-NativeCommandSucceeded "Reading encode job"
    $encoderPods = kubectl get pods --namespace $KubernetesNamespace `
        --selector "app.kubernetes.io/name=video-encoder,video/job-id=$labelValue" `
        --output json | ConvertFrom-Json
    Assert-NativeCommandSucceeded "Reading encoder pods"

    kubectl wait --namespace $KubernetesNamespace --for=create "job/$stitchJobName" --timeout="${TimeoutMinutes}m"
    Assert-NativeCommandSucceeded "Waiting for stitch job creation"
    kubectl wait --namespace $KubernetesNamespace --for=condition=complete "job/$stitchJobName" --timeout="${TimeoutMinutes}m"
    Assert-NativeCommandSucceeded "Waiting for stitch job completion"
    $stitchJob = kubectl get job $stitchJobName --namespace $KubernetesNamespace --output json | ConvertFrom-Json
    Assert-NativeCommandSucceeded "Reading stitch job"
    $stitchPods = kubectl get pods --namespace $KubernetesNamespace `
        --selector "app.kubernetes.io/name=video-stitcher,video/job-id=$labelValue" `
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
            image = $containerStatus.image
            imageId = $containerStatus.imageID
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
            image = $containerStatus.image
            imageId = $containerStatus.imageID
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
        mediaRuntime = $MediaRuntime
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