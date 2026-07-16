#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NtfsRoot,

    [Parameter(Mandatory)]
    [string]$RefsRoot,

    [Parameter(Mandatory)]
    [string]$Source
)

$ErrorActionPreference = 'Stop'

function Assert-DirectoryRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label nao encontrado ou nao e um diretorio: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Resolve-SourceItem {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ([System.IO.Path]::GetExtension($Path) -ne '.zip') {
            throw "Arquivo de origem nao e um ZIP: $Path"
        }

        return [pscustomobject]@{
            Path = (Resolve-Path -LiteralPath $Path).ProviderPath
            Type = 'Zip'
        }
    }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        return [pscustomobject]@{
            Path = (Resolve-Path -LiteralPath $Path).ProviderPath
            Type = 'Folder'
        }
    }

    throw "Origem nao encontrada: $Path"
}

function Write-BenchmarkHeader {
    param(
        [Parameter(Mandatory)][string]$NtfsRoot,
        [Parameter(Mandatory)][string]$RefsRoot,
        [Parameter(Mandatory)][pscustomobject]$SourceInfo
    )

    Write-Host "Benchmark de Builds entre particao NTFS e Dev Drive (ReFS)" -ForegroundColor Cyan
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "Raiz NTFS: $NtfsRoot"
    Write-Host "Raiz ReFS: $RefsRoot"
    Write-Host "Origem ($($SourceInfo.Type)): $($SourceInfo.Path)"
}

function Get-ZipTopLevelFolder {
    param(
        [Parameter(Mandatory)][string]$ZipPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $fileEntries = $zip.Entries | Where-Object {
            $_.FullName -and
            -not $_.FullName.EndsWith('/') -and
            $_.FullName -notmatch '^__MACOSX/'
        }

        $hasRootFile = $false
        $topFolders = New-Object System.Collections.Generic.HashSet[string]

        foreach ($entry in $fileEntries) {
            $parts = ($entry.FullName -replace '\\', '/').Split('/')
            if ($parts.Length -eq 1) {
                $hasRootFile = $true
                break
            }
            [void]$topFolders.Add($parts[0])
        }

        if ($hasRootFile -or $topFolders.Count -ne 1) {
            return $null
        }

        return [System.Linq.Enumerable]::First($topFolders)
    } finally {
        $zip.Dispose()
    }
}

function Get-ProjectName {
    param(
        [Parameter(Mandatory)][pscustomobject]$SourceInfo
    )

    if ($SourceInfo.Type -eq 'Folder') {
        return Split-Path -Path $SourceInfo.Path -Leaf
    }

    $topFolder = Get-ZipTopLevelFolder -ZipPath $SourceInfo.Path
    if ($topFolder) {
        return $topFolder
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($SourceInfo.Path)
}

function New-CleanDirectory {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Copy-FolderContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $robocopyArgs = @(
        $Source,
        $Destination,
        '/E', '/R:2', '/W:1',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/NC', '/NS'
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        robocopy @robocopyArgs | Out-Null
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    $robocopyExitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0

    if ($robocopyExitCode -ge 8) {
        throw "Robocopy falhou (codigo $robocopyExitCode) ao copiar '$Source' para '$Destination'"
    }
}

function Expand-ZipContents {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )

    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("umbenchmark_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $scratch -Force

        $topFolder = Get-ZipTopLevelFolder -ZipPath $ZipPath
        $contentRoot = if ($topFolder) { Join-Path $scratch $topFolder } else { $scratch }

        Copy-FolderContents -Source $contentRoot -Destination $Destination
    } finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-EnvironmentCopy {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$SourceInfo,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$Label
    )

    $destination = Join-Path $Root $ProjectName
    Write-Host "Preparando copia $Label em: $destination"

    $destination = New-CleanDirectory -Path $destination

    if ($SourceInfo.Type -eq 'Folder') {
        Copy-FolderContents -Source $SourceInfo.Path -Destination $destination
    } else {
        Expand-ZipContents -ZipPath $SourceInfo.Path -Destination $destination
    }

    return $destination
}

# --- Orquestracao ---

$resolvedNtfsRoot = Assert-DirectoryRoot -Path $NtfsRoot -Label 'Raiz NTFS'
$resolvedRefsRoot = Assert-DirectoryRoot -Path $RefsRoot -Label 'Raiz ReFS'
$sourceInfo = Resolve-SourceItem -Path $Source

Write-BenchmarkHeader -NtfsRoot $resolvedNtfsRoot -RefsRoot $resolvedRefsRoot -SourceInfo $sourceInfo

$projectName = Get-ProjectName -SourceInfo $sourceInfo

$envAPath = Initialize-EnvironmentCopy -Root $resolvedNtfsRoot -SourceInfo $sourceInfo -ProjectName $projectName -Label 'A (NTFS)'
$envBPath = Initialize-EnvironmentCopy -Root $resolvedRefsRoot -SourceInfo $sourceInfo -ProjectName $projectName -Label 'B (ReFS)'

Write-Host ''
Write-Host "Ambiente A (NTFS): $envAPath" -ForegroundColor Yellow
Write-Host "Ambiente B (ReFS): $envBPath" -ForegroundColor Yellow
