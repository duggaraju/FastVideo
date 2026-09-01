#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [string] $ResourceGroup = "$([Environment]::UserName)-video",
    [ValidateRange(1, 10)]
    [int] $Pairs = 5,
    [ValidateRange(0, 100)]
    [int] $PairOffset = 0,
    [string] $AcrLoginServer,
    [string] $DotNetMediaImageTag = "latest",
    [string] $RustMediaImageTag = "latest",
    [ValidateSet("auto", "storagequeue", "servicebus")]
    [string] $MessageTransport = "auto",
    [string] $KubernetesNamespace,
    [string] $BatchPrefix = "paired-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [string] $OutputPath = (Join-Path $PSScriptRoot "bench-paired-dotnet-rust-loopback-vmaf.json")
)

$ErrorActionPreference = "Stop"
$workspaceRoot = Split-Path $PSScriptRoot -Parent
$benchmarkScript = Join-Path $PSScriptRoot "benchmark-workflow.ps1"

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

function Set-MediaRuntimeImages([string] $LoginServer, [string] $DotNetTag, [string] $RustTag, [string] $AnalysisDeployment, [string] $CompletionDeployment) {
    $dotnetImages = @{
        encode = "$LoginServer/video-encoder-dotnet:$DotNetTag"
        audio = "$LoginServer/video-audio-encoder-dotnet:$DotNetTag"
        stitch = "$LoginServer/video-stitcher-dotnet:$DotNetTag"
    }
    $rustImages = @{
        encode = "$LoginServer/video-encoder-rust:$RustTag"
        audio = "$LoginServer/video-audio-encoder-rust:$RustTag"
        stitch = "$LoginServer/video-stitcher-rust:$RustTag"
    }

    $patch = @{
        data = @{
            Images__Dotnet__Encoder = $dotnetImages.encode
            Images__Dotnet__AudioEncoder = $dotnetImages.audio
            Images__Dotnet__Stitcher = $dotnetImages.stitch
            Images__Rust__Encoder = $rustImages.encode
            Images__Rust__AudioEncoder = $rustImages.audio
            Images__Rust__Stitcher = $rustImages.stitch
        }
    } | ConvertTo-Json -Compress
    kubectl patch configmap video-config --namespace $KubernetesNamespace --type merge --patch $patch | Out-Host
    Assert-NativeCommandSucceeded "Updating media runtime images"

    $jobTemplatesConfigMap = kubectl get configmap video-job-templates --namespace $KubernetesNamespace -o json | ConvertFrom-Json -Depth 20
    Assert-NativeCommandSucceeded "Reading job template config map"

    $jobTemplateUpdates = @{}
    foreach ($property in $jobTemplatesConfigMap.data.PSObject.Properties) {
        $image = $null
        switch -Regex ($property.Name) {
            '^encode-dotnet(?:-|\.yaml$)' { $image = $dotnetImages.encode; break }
            '^audio-encode-dotnet(?:-|\.yaml$)' { $image = $dotnetImages.audio; break }
            '^stitch-dotnet(?:-|\.yaml$)' { $image = $dotnetImages.stitch; break }
            '^encode-rust(?:-|\.yaml$)' { $image = $rustImages.encode; break }
            '^audio-encode-rust(?:-|\.yaml$)' { $image = $rustImages.audio; break }
            '^stitch-rust(?:-|\.yaml$)' { $image = $rustImages.stitch; break }
            default { continue }
        }

        $jobTemplateUpdates[$property.Name] = [regex]::Replace(
            [string] $property.Value,
            '(?m)^(\s*image:\s*).+$',
            ('$1' + $image))
    }

    if ($jobTemplateUpdates.Count -eq 0) {
        throw "video-job-templates does not contain any rendered media job templates to patch."
    }

    $jobTemplatePatch = @{ data = $jobTemplateUpdates } | ConvertTo-Json -Compress -Depth 20
    kubectl patch configmap video-job-templates --namespace $KubernetesNamespace --type merge --patch $jobTemplatePatch | Out-Host
    Assert-NativeCommandSucceeded "Updating job template images"

    kubectl rollout restart "deployment/$AnalysisDeployment" --namespace $KubernetesNamespace | Out-Host
    Assert-NativeCommandSucceeded "Restarting analysis"
    kubectl rollout restart "deployment/$CompletionDeployment" --namespace $KubernetesNamespace | Out-Host
    Assert-NativeCommandSucceeded "Restarting completion"
    kubectl scale "deployment/$AnalysisDeployment" --namespace $KubernetesNamespace --replicas=1 | Out-Host
    Assert-NativeCommandSucceeded "Scaling analysis"
    kubectl rollout status "deployment/$AnalysisDeployment" --namespace $KubernetesNamespace --timeout=5m | Out-Host
    Assert-NativeCommandSucceeded "Waiting for analysis"
    kubectl rollout status "deployment/$CompletionDeployment" --namespace $KubernetesNamespace --timeout=5m | Out-Host
    Assert-NativeCommandSucceeded "Waiting for completion"
}

function Start-Benchmark([string] $Runtime, [string] $BatchId, [string] $ResultPath) {
    Start-Job -ScriptBlock {
        param($Root, $ScriptPath, $Group, $MediaRuntime, $Transport, $Batch, $Path, $InheritedPath)
        $env:PATH = $InheritedPath
        Set-Location $Root
        & $ScriptPath `
            -ResourceGroup $Group `
            -Runs 1 `
            -CapacityClass interruptible `
            -MediaRuntime $MediaRuntime `
            -MessageTransport $Transport `
            -Architecture amd64 `
            -CalculateVmaf $true `
            -TimeoutMinutes 30 `
            -BatchId $Batch `
            -OutputPath $Path
    } -ArgumentList $workspaceRoot, $benchmarkScript, $ResourceGroup, $Runtime, $MessageTransport, $BatchId, $ResultPath, $env:PATH
}

foreach ($command in @("az", "kubectl")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

$deploymentQuery = if ($MessageTransport -eq "auto") {
    "sort_by([?properties.provisioningState=='Succeeded' && properties.outputs.acrLoginServer != null], &properties.timestamp)[-1].name"
} else {
    "sort_by([?properties.provisioningState=='Succeeded' && properties.outputs.acrLoginServer != null && properties.outputs.messageTransport.value=='$MessageTransport'], &properties.timestamp)[-1].name"
}
$deploymentName = az deployment group list `
    --resource-group $ResourceGroup `
    --query $deploymentQuery `
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
Assert-NativeCommandSucceeded "Reading deployment outputs"
$deployment = $deploymentJson | ConvertFrom-Json
$deployedTransport = [string]$deployment.messageTransport.value
if ([string]::IsNullOrWhiteSpace($deployedTransport)) {
    $deployedTransport = if (-not [string]::IsNullOrWhiteSpace([string]$deployment.outputQueueServiceUri.value)) { "storagequeue" } else { "servicebus" }
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

if ([string]::IsNullOrWhiteSpace($AcrLoginServer)) {
    $AcrLoginServer = az deployment group show `
        --resource-group $ResourceGroup `
        --name $deploymentName `
        --query properties.outputs.acrLoginServer.value `
        --output tsv
    Assert-NativeCommandSucceeded "Reading ACR login server from deployment '$deploymentName'"
}
$analysisDeployment = if ($MessageTransport -eq "storagequeue") { "video-analyzer-storagequeue" } else { "video-analysis-servicebus" }
$completionDeployment = if ($MessageTransport -eq "storagequeue") { "video-completion-storagequeue" } else { "video-completion-servicebus" }
$analysisScaledObject = $analysisDeployment
$results = @()
Set-MediaRuntimeImages $AcrLoginServer $DotNetMediaImageTag $RustMediaImageTag $analysisDeployment $completionDeployment
kubectl patch "scaledobject/$analysisScaledObject" --namespace $KubernetesNamespace --type merge --patch '{"spec":{"minReplicaCount":1}}' | Out-Host
Assert-NativeCommandSucceeded "Holding analysis at one replica"

try {
    for ($index = 1; $index -le $Pairs; $index++) {
        $pair = $PairOffset + $index
        $order = if ($pair % 2 -eq 1) { @("dotnet", "rust") } else { @("rust", "dotnet") }
        $pairRuns = @{}
        foreach ($runtime in $order) {
            $batchId = "$BatchPrefix-p$pair-$runtime"
            $pairRuns[$runtime] = [pscustomobject]@{
                BatchId = $batchId
                ResultPath = Join-Path $PSScriptRoot "$batchId.json"
            }
        }

        Write-Host "[$index/$Pairs] Starting $($order[0]) first, then $($order[1])"
        $background = Start-Benchmark $order[0] $pairRuns[$order[0]].BatchId $pairRuns[$order[0]].ResultPath
        try {
            $firstJobId = "$($pairRuns[$order[0]].BatchId)-1"
            $firstJobName = "encode-$(Get-LabelValue $firstJobId)"
            kubectl wait --namespace $KubernetesNamespace --for=create "job/$firstJobName" --timeout=10m | Out-Host
            Assert-NativeCommandSucceeded "Waiting for the first encode job"

            & $benchmarkScript `
                -ResourceGroup $ResourceGroup `
                -Runs 1 `
                -CapacityClass interruptible `
                -MediaRuntime $order[1] `
                -MessageTransport $MessageTransport `
                -Architecture amd64 `
                -CalculateVmaf $true `
                -TimeoutMinutes 30 `
                -BatchId $pairRuns[$order[1]].BatchId `
                -OutputPath $pairRuns[$order[1]].ResultPath

            Wait-Job $background | Out-Null
            if (-not (Test-Path $pairRuns[$order[0]].ResultPath)) {
                throw "The $($order[0]) benchmark did not produce a result: $($background.ChildJobs[0].JobStateInfo.Reason)"
            }
        }
        finally {
            if ($background.State -eq "Running") {
                Stop-Job $background
            }
            Remove-Job $background -Force
        }

        $pairResults = @{}
        foreach ($runtime in @("dotnet", "rust")) {
            $row = @(Get-Content $pairRuns[$runtime].ResultPath -Raw | ConvertFrom-Json)[0]
            $row | Add-Member -NotePropertyName pair -NotePropertyValue $pair -Force
            $row | Add-Member -NotePropertyName startOrder -NotePropertyValue ($order -join ",") -Force
            $pairResults[$runtime] = $row
            $results += $row
        }

        $overlapStart = @(
            [DateTimeOffset]$pairResults.dotnet.encodeStartedAt,
            [DateTimeOffset]$pairResults.rust.encodeStartedAt
        ) | Sort-Object | Select-Object -Last 1
        $overlapEnd = @(
            [DateTimeOffset]$pairResults.dotnet.encodeCompletedAt,
            [DateTimeOffset]$pairResults.rust.encodeCompletedAt
        ) | Sort-Object | Select-Object -First 1
        $overlapSeconds = ($overlapEnd - $overlapStart).TotalSeconds
        foreach ($row in $pairResults.Values) {
            $row | Add-Member -NotePropertyName encodeOverlapSeconds -NotePropertyValue $overlapSeconds -Force
        }

        $results | Sort-Object pair, mediaRuntime | ConvertTo-Json -Depth 8 | Set-Content $OutputPath -Encoding utf8
        Write-Host "[$index/$Pairs] .NET=$($pairResults.dotnet.encodeRunSeconds)s Rust=$($pairResults.rust.encodeRunSeconds)s overlap=$($overlapSeconds)s"
    }
}
finally {
    kubectl patch "scaledobject/$analysisScaledObject" --namespace $KubernetesNamespace --type merge --patch '{"spec":{"minReplicaCount":0}}' | Out-Host
    kubectl scale "deployment/$analysisDeployment" --namespace $KubernetesNamespace --replicas=0 | Out-Host
}

Write-Host "Paired results: $OutputPath"
