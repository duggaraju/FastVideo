#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [string] $AcrName,
    [string] $ImageTag = "latest",
    [ValidateSet("storagequeue", "servicebus")]
    [string] $MessageTransport = "storagequeue",
    [ValidateSet("btbn", "custom")]
    [string] $FfmpegBuild = "btbn",
    [string] $FfmpegVersion = "9.0",
    [string] $Platforms = "linux/amd64",
    [switch] $AcrBuild
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$controlPlanePlatforms = "linux/amd64"
$localNuGetSource = "https://packagefeedproxy.microsoft.io/nuget/v3/index.json"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or later is required."
}
if ($AcrBuild -and [string]::IsNullOrWhiteSpace($AcrName)) {
    throw "AcrName is required for an ACR build."
}
if ([string]::IsNullOrWhiteSpace($AcrName) -and $Platforms.Contains(',')) {
    throw "A local non-pushing build supports one media platform at a time. Specify one platform or provide AcrName to push a multi-platform image."
}

function Assert-NativeCommandSucceeded([string] $Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

$acrLoginServer = ""
if (-not [string]::IsNullOrWhiteSpace($AcrName)) {
    $acrLoginServer = az acr show --name $AcrName --query loginServer --output tsv
    Assert-NativeCommandSucceeded "Reading Azure Container Registry '$AcrName'"
    if ([string]::IsNullOrWhiteSpace($acrLoginServer)) {
        throw "Azure Container Registry '$AcrName' did not return a login server."
    }
    if (-not $AcrBuild) {
        az acr login --name $AcrName
        Assert-NativeCommandSucceeded "Logging in to Azure Container Registry '$AcrName'"
    }
}

$buildTargets = foreach ($project in @("Analysis", "Completion", "Encoder", "AudioEncoder", "Stitcher")) {
    $isControlPlaneWorker = $project -in @("Analysis", "Completion")
    $buildRuntimes = if ($isControlPlaneWorker) {
        @($(if ($MessageTransport -eq "storagequeue") { "rust" } else { "dotnet" }))
    } else {
        @("dotnet", "rust")
    }
    foreach ($buildRuntime in $buildRuntimes) {
        [PSCustomObject]@{ Project = $project; Runtime = $buildRuntime }
    }
}

foreach ($buildTarget in $buildTargets) {
    $project = $buildTarget.Project
    $buildRuntime = $buildTarget.Runtime
    $projectName = "Video$project"
    $isControlPlaneWorker = $project -in @("Analysis", "Completion")
    $imageName = if ($isControlPlaneWorker) {
        "video-$($project.ToLowerInvariant())-$MessageTransport"
    } elseif ($project -eq "AudioEncoder") {
        "video-audio-encoder-$buildRuntime"
    } else {
        "video-$($project.ToLowerInvariant())-$buildRuntime"
    }
    $registryPrefix = if ([string]::IsNullOrWhiteSpace($acrLoginServer)) { "" } else { "$acrLoginServer/" }
    $fullImage = "${registryPrefix}${imageName}:${ImageTag}"
    $projectPlatforms = if ($isControlPlaneWorker) { $controlPlanePlatforms } else { $Platforms }
    $isRustWorker = $buildRuntime -eq "rust"
    $dockerfile = Join-Path $root $(if ($isRustWorker) { "rust/Dockerfile" } else { "dotnet/Dockerfile" })
    $package = ""
    $buildArguments = if ($isRustWorker) {
        $package = switch ($project) {
            "Analysis" { "analyzer" }
            "Completion" { "completion" }
            "AudioEncoder" { "audio-encoder" }
            default { $project.ToLowerInvariant() }
        }
        @(
            "--build-arg", "PACKAGE=$package",
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

    if (-not $AcrBuild) {
        if (-not $isRustWorker) {
            $buildArguments += @("--build-arg", "NUGET_SOURCE=$localNuGetSource")
        }
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
            if (-not [string]::IsNullOrWhiteSpace($AcrName)) {
                docker push $fullImage
                Assert-NativeCommandSucceeded "Pushing $projectName image"
            }
        }
        continue
    }

    $platformList = @($projectPlatforms.Split(',', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() })
    $platformImages = @()
    $dockerfileRelativePath = [IO.Path]::GetRelativePath($root, $dockerfile).Replace([IO.Path]::DirectorySeparatorChar, '/')
    foreach ($platform in $platformList) {
        $platformSuffix = $platform.Replace('linux/', '')
        $platformImage = "${imageName}:${ImageTag}-${platformSuffix}"
        $taskValues = @(
            "image=$platformImage",
            "platform=$platform",
            "targetArch=$platformSuffix",
            "dockerfile=$dockerfileRelativePath",
            "project=$(if ($isRustWorker) { '' } else { $projectName })",
            "appDll=$(if ($isRustWorker) { '' } else { "$projectName.dll" })",
            "package=$package",
            "ffmpegBuild=$FfmpegBuild",
            "ffmpegVersion=$FfmpegVersion"
        )
        $acrRunArguments = @("acr", "run", "--registry", $AcrName, "--file", "deploy/acr-build.yaml")
        foreach ($taskValue in $taskValues) {
            $acrRunArguments += @("--set", $taskValue)
        }
        $acrRunArguments += $root
        az @acrRunArguments
        Assert-NativeCommandSucceeded "Building and pushing $projectName image for $platform with the Azure Container Registry task"
        $platformImages += "${acrLoginServer}/${platformImage}"
    }
    if ($platformImages.Count -gt 1) {
        az acr run `
            --registry $AcrName `
            --file deploy/acr-manifest.yaml `
            --set "image=${imageName}:${ImageTag}" `
            --set "amd64Image=${imageName}:${ImageTag}-amd64" `
            --set "arm64Image=${imageName}:${ImageTag}-arm64" `
            $root
        Assert-NativeCommandSucceeded "Creating multi-platform manifest for $projectName in Azure Container Registry"
    } else {
        az acr import `
            --name $AcrName `
            --source $platformImages[0] `
            --image "${imageName}:${ImageTag}" `
            --force
        Assert-NativeCommandSucceeded "Tagging $projectName image"
    }
}