#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NtfsRoot,

    [Parameter(Mandatory)]
    [string]$RefsRoot,

    [Parameter(Mandatory)]
    [string]$Source,

    [string]$ConfigCommand = "java `"$PSScriptRoot\Ferramentas\CriarVariaveisEAbrirConsole.java`""
)

$ErrorActionPreference = 'Stop'

$AutoRunToolPath = Join-Path $PSScriptRoot 'Ferramentas\DescarregarVariaveis.cmd'
$CapturedEnvFilePath = Join-Path $PSScriptRoot 'Ferramentas\VarAmb.txt'
$script:CurrentStage = 'Inicializacao'

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

function Invoke-BuildConfigTool {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigCommand
    )

    Write-Host "Configurando requisitos de build em: $ProjectRoot"
    Write-Host "Comando: $ConfigCommand"

    Push-Location -LiteralPath $ProjectRoot
    try {
        Invoke-Expression $ConfigCommand
    } finally {
        Pop-Location
    }
}

function Set-CmdAutoRun {
    param(
        [Parameter(Mandatory)][string]$Command
    )

    $keyPath = 'HKCU:\Software\Microsoft\Command Processor'
    $keyCreated = -not (Test-Path $keyPath)

    if ($keyCreated) {
        New-Item -Path $keyPath -Force | Out-Null
    }

    $previousValue = (Get-ItemProperty -Path $keyPath -Name 'AutoRun' -ErrorAction SilentlyContinue).AutoRun

    Set-ItemProperty -Path $keyPath -Name 'AutoRun' -Value $Command

    return [pscustomobject]@{
        KeyCreated    = $keyCreated
        PreviousValue = $previousValue
    }
}

function Restore-CmdAutoRun {
    param(
        [Parameter(Mandatory)][pscustomobject]$PreviousState
    )

    $keyPath = 'HKCU:\Software\Microsoft\Command Processor'

    if ($PreviousState.KeyCreated) {
        Remove-Item -Path $keyPath -Force -ErrorAction SilentlyContinue
        return
    }

    if ($null -eq $PreviousState.PreviousValue) {
        Remove-ItemProperty -Path $keyPath -Name 'AutoRun' -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -Path $keyPath -Name 'AutoRun' -Value $PreviousState.PreviousValue
    }
}

function Wait-ForFileReady {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 60,
        [int]$PollMilliseconds = 200
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while (-not (Test-Path -LiteralPath $Path)) {
        if ((Get-Date) -gt $deadline) {
            throw "Tempo esgotado aguardando o arquivo: $Path"
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }

    while ($true) {
        try {
            $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
            $stream.Close()
            return
        } catch {
            if ((Get-Date) -gt $deadline) {
                throw "Tempo esgotado aguardando liberacao do arquivo: $Path"
            }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }
}

function Import-CapturedEnvironment {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding OEM) {
        $line = $rawLine -replace '[\x00-\x08\x0b\x0c\x0e-\x1f]', ''

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $separatorIndex = $line.IndexOf('=')
        if ($separatorIndex -le 0) {
            Write-Host "Linha ignorada (sem '='): $line" -ForegroundColor DarkYellow
            continue
        }

        $name = $line.Substring(0, $separatorIndex)
        $value = $line.Substring($separatorIndex + 1)

        if ($name -notmatch '^[^\x00-\x1f:]+$') {
            Write-Host "Linha ignorada (nome de variavel invalido): $line" -ForegroundColor DarkYellow
            continue
        }

        if ([string]::IsNullOrEmpty($value)) {
            Write-Host "Linha ignorada (sem valor): $name" -ForegroundColor DarkYellow
            continue
        }

        $previousValue = [System.Environment]::GetEnvironmentVariable($name, 'Process')

        if ($null -eq $previousValue) {
            Write-Host "Variavel nova: $name = '$value'"
        } elseif ($previousValue -ne $value) {
            Write-Host "Variavel alterada: $name = '$previousValue' -> '$value'"
        }

        Set-Item -Path "Env:$name" -Value $value
    }
}

function Close-RecentCmdConsoles {
    param(
        [int]$WithinSeconds = 2
    )

    $threshold = (Get-Date).AddSeconds(-$WithinSeconds)
    $candidates = Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" |
        Where-Object { $_.CreationDate -ge $threshold }

    foreach ($proc in $candidates) {
        Write-Host "Encerrando console de configuracao: PID $($proc.ProcessId) (criado em $($proc.CreationDate))"
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-BuildConfiguration {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigCommand,
        [Parameter(Mandatory)][string]$AutoRunToolPath,
        [Parameter(Mandatory)][string]$CapturedEnvFile
    )

    $previousAutoRun = Set-CmdAutoRun -Command "`"$AutoRunToolPath`""

    try {
        Invoke-BuildConfigTool -ProjectRoot $ProjectRoot -ConfigCommand $ConfigCommand
        Wait-ForFileReady -Path $CapturedEnvFile
    } finally {
        Restore-CmdAutoRun -PreviousState $previousAutoRun
    }

    $lineCount = (Get-Content -LiteralPath $CapturedEnvFile -Encoding OEM | Measure-Object).Count
    Write-Host "Arquivo de variaveis gerado: $CapturedEnvFile ($lineCount linhas)"

    Import-CapturedEnvironment -Path $CapturedEnvFile

    Close-RecentCmdConsoles
}

function Write-Stage {
    param(
        [Parameter(Mandatory)][string]$Message
    )

    $script:CurrentStage = $Message

    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-BenchmarkError {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)]$ErrorRecord
    )

    Write-Host ''
    Write-Host "ERRO na etapa '$Stage': $($ErrorRecord.Exception.Message)" -ForegroundColor Red
}

function Invoke-EmergencyCleanup {
    param(
        [Parameter(Mandatory)][string]$AutoRunToolPath,
        [Parameter(Mandatory)][string]$CapturedEnvFile
    )

    $keyPath = 'HKCU:\Software\Microsoft\Command Processor'
    $expectedAutoRun = "`"$AutoRunToolPath`""
    $currentAutoRun = (Get-ItemProperty -Path $keyPath -Name 'AutoRun' -ErrorAction SilentlyContinue).AutoRun

    if ($currentAutoRun -eq $expectedAutoRun) {
        Remove-ItemProperty -Path $keyPath -Name 'AutoRun' -ErrorAction SilentlyContinue
        Write-Host "Limpeza de emergencia: entrada AutoRun removida." -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $CapturedEnvFile) {
        Write-Host "Arquivo de variaveis mantido para depuracao: $CapturedEnvFile" -ForegroundColor Yellow
    }
}

# --- Orquestracao ---

try {
    Write-Stage 'Validando parametros e origem'

    $resolvedNtfsRoot = Assert-DirectoryRoot -Path $NtfsRoot -Label 'Raiz NTFS'
    $resolvedRefsRoot = Assert-DirectoryRoot -Path $RefsRoot -Label 'Raiz ReFS'
    $sourceInfo = Resolve-SourceItem -Path $Source

    Write-BenchmarkHeader -NtfsRoot $resolvedNtfsRoot -RefsRoot $resolvedRefsRoot -SourceInfo $sourceInfo

    $projectName = Get-ProjectName -SourceInfo $sourceInfo

    Write-Stage 'Criando diretorios de build'

    $envAPath = Initialize-EnvironmentCopy -Root $resolvedNtfsRoot -SourceInfo $sourceInfo -ProjectName $projectName -Label 'A (NTFS)'
    $envBPath = Initialize-EnvironmentCopy -Root $resolvedRefsRoot -SourceInfo $sourceInfo -ProjectName $projectName -Label 'B (ReFS)'

    Write-Host "Ambiente A (NTFS): $envAPath"
    Write-Host "Ambiente B (ReFS): $envBPath"

    Write-Stage 'Configurando o ambiente de build'

    Initialize-BuildConfiguration -ProjectRoot $envAPath -ConfigCommand $ConfigCommand -AutoRunToolPath $AutoRunToolPath -CapturedEnvFile $CapturedEnvFilePath

    Remove-Item -LiteralPath $CapturedEnvFilePath -Force
    Write-Host "Arquivo de variaveis removido: $CapturedEnvFilePath"
}
catch {
    Write-BenchmarkError -Stage $script:CurrentStage -ErrorRecord $_
    Invoke-EmergencyCleanup -AutoRunToolPath $AutoRunToolPath -CapturedEnvFile $CapturedEnvFilePath
    exit 1
}
