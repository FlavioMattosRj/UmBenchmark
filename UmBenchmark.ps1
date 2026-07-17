#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NtfsRoot,

    [Parameter(Mandatory)]
    [string]$RefsRoot,

    [Parameter(Mandatory)]
    [string]$Source,

    [string]$ConfigCommand = "java `"$PSScriptRoot\Ferramentas\CriarVariaveisEAbrirConsole.java`"",

    [int]$Iterations = 5,

    [string]$BuildCommand = 'mvn clean package',

    [switch]$ShowBuildOutput
)

$ErrorActionPreference = 'Stop'

$AutoRunToolPath = Join-Path $PSScriptRoot 'Ferramentas\DescarregarVariaveis.cmd'
$CapturedEnvFilePath = Join-Path $PSScriptRoot 'Ferramentas\VarAmb.txt'
$ResultsFolderPath = Join-Path $PSScriptRoot 'Resultados'
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
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)" -ForegroundColor Blue
    Write-Host "Raiz NTFS: $NtfsRoot" -ForegroundColor Blue
    Write-Host "Raiz ReFS: $RefsRoot" -ForegroundColor Blue
    Write-Host "Origem ($($SourceInfo.Type)): $($SourceInfo.Path)" -ForegroundColor Blue
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
    Write-Host "Preparando copia $Label em: $destination" -ForegroundColor Blue

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

    Write-Host "Configurando requisitos de build em: $ProjectRoot" -ForegroundColor Blue
    Write-Host "Comando: $ConfigCommand" -ForegroundColor Blue

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

function Format-DisplayValue {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    if ($Value.Length -le 80) {
        return $Value
    }

    return "$($Value.Substring(0, 30)) (...)"
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
            Write-Host "Variavel nova: $name = '$(Format-DisplayValue $value)'" -ForegroundColor Blue
        } elseif ($previousValue -ne $value) {
            Write-Host "Variavel alterada: $name = '$(Format-DisplayValue $previousValue)' -> '$(Format-DisplayValue $value)'" -ForegroundColor Blue
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
        Write-Host "Encerrando console de configuracao: PID $($proc.ProcessId) (criado em $($proc.CreationDate))" -ForegroundColor Blue
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
    Write-Host "Arquivo de variaveis gerado: $CapturedEnvFile ($lineCount linhas)" -ForegroundColor Blue

    Import-CapturedEnvironment -Path $CapturedEnvFile

    Close-RecentCmdConsoles

    Remove-Item -LiteralPath $CapturedEnvFile -Force
    Write-Host "Arquivo de variaveis removido: $CapturedEnvFile" -ForegroundColor Blue
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

function Set-MavenRepoLocal {
    param(
        [Parameter(Mandatory)][string]$RepoPath
    )

    $current = $env:MAVEN_OPTS
    $flag = "-Dmaven.repo.local=`"$RepoPath`""

    if ($current -match '-Dmaven\.repo\.local=("[^"]*"|\S+)') {
        $env:MAVEN_OPTS = $current -replace '-Dmaven\.repo\.local=("[^"]*"|\S+)', $flag
    } elseif ([string]::IsNullOrWhiteSpace($current)) {
        $env:MAVEN_OPTS = $flag
    } else {
        $env:MAVEN_OPTS = "$current $flag"
    }
}

function Initialize-PackageCacheRedirection {
    param(
        [Parameter(Mandatory)][string]$ProjectPath
    )

    $cacheRoot = Join-Path $ProjectPath '.cache-pacotes'
    $npmCache = Join-Path $cacheRoot 'npm'
    $denoCache = Join-Path $cacheRoot 'deno'
    $mavenCache = Join-Path $cacheRoot 'maven'

    New-Item -ItemType Directory -Path $npmCache, $denoCache, $mavenCache -Force | Out-Null

    $env:NPM_CONFIG_CACHE = $npmCache
    $env:DENO_DIR = $denoCache
    Set-MavenRepoLocal -RepoPath $mavenCache
}

function Invoke-ProjectBuild {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$BuildCommand,
        [switch]$ShowBuildOutput
    )

    Initialize-PackageCacheRedirection -ProjectPath $ProjectPath

    Write-Host "`tBuild: $ProjectPath" -ForegroundColor Blue

    $elapsed = Measure-Command {
        Push-Location -LiteralPath $ProjectPath
        try {
            if ($ShowBuildOutput) {
                Invoke-Expression $BuildCommand | Write-Host
            } else {
                Invoke-Expression $BuildCommand | Out-Null
            }
        } finally {
            Pop-Location
        }
    }

    Write-Host "`tBuild concluido com sucesso em $([math]::Round($elapsed.TotalSeconds, 2)) s" -ForegroundColor Blue

    return $elapsed
}

function Save-BenchmarkResults {
    param(
        [Parameter(Mandatory)][object[]]$Samples,
        [Parameter(Mandatory)][string]$ResultsFolder
    )

    if (-not (Test-Path -LiteralPath $ResultsFolder)) {
        New-Item -ItemType Directory -Path $ResultsFolder -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $csvPath = Join-Path $ResultsFolder "Resultados_$timestamp.csv"

    $Samples | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    Write-Host "Resultados salvos em: $csvPath" -ForegroundColor Blue

    return $csvPath
}

function Invoke-Benchmark {
    param(
        [Parameter(Mandatory)][string]$EnvAPath,
        [Parameter(Mandatory)][string]$EnvBPath,
        [Parameter(Mandatory)][int]$Iterations,
        [Parameter(Mandatory)][string]$BuildCommand,
        [Parameter(Mandatory)][string]$ResultsFolder,
        [switch]$ShowBuildOutput
    )

    Write-Host "Warmup: preenchendo caches de dependencias em cada ambiente..." -ForegroundColor Blue

    $samples = @(
        $warmupA = Invoke-ProjectBuild -ProjectPath $EnvAPath -BuildCommand $BuildCommand -ShowBuildOutput:$ShowBuildOutput
        [pscustomobject]@{
            Ambiente = 'A (NTFS)'
            Rodada   = 'Warmup'
            Segundos = [math]::Round($warmupA.TotalSeconds, 2)
        }

        $warmupB = Invoke-ProjectBuild -ProjectPath $EnvBPath -BuildCommand $BuildCommand -ShowBuildOutput:$ShowBuildOutput
        [pscustomobject]@{
            Ambiente = 'B (ReFS)'
            Rodada   = 'Warmup'
            Segundos = [math]::Round($warmupB.TotalSeconds, 2)
        }

        for ($i = 1; $i -le $Iterations; $i++) {
            Write-Host "Iteracao $i de $Iterations" -ForegroundColor Blue

            $elapsedA = Invoke-ProjectBuild -ProjectPath $EnvAPath -BuildCommand $BuildCommand -ShowBuildOutput:$ShowBuildOutput
            [pscustomobject]@{
                Ambiente = 'A (NTFS)'
                Rodada   = $i
                Segundos = [math]::Round($elapsedA.TotalSeconds, 2)
            }

            $elapsedB = Invoke-ProjectBuild -ProjectPath $EnvBPath -BuildCommand $BuildCommand -ShowBuildOutput:$ShowBuildOutput
            [pscustomobject]@{
                Ambiente = 'B (ReFS)'
                Rodada   = $i
                Segundos = [math]::Round($elapsedB.TotalSeconds, 2)
            }
        }
    )

    $csvPath = Save-BenchmarkResults -Samples $samples -ResultsFolder $ResultsFolder

    return [pscustomobject]@{
        Samples = $samples
        CsvPath = $csvPath
    }
}

function Show-BenchmarkSummary {
    param(
        [Parameter(Mandatory)][object[]]$Samples
    )

    Write-Host ''
    Write-Host 'Medicoes individuais (warmup e iteracoes):' -ForegroundColor Blue

    $Samples | Format-Table -AutoSize

    Write-Host ''
    Write-Host 'Resumo do benchmark:' -ForegroundColor Blue

    $Samples | Where-Object { $_.Rodada -ne 'Warmup' } | Group-Object Ambiente | ForEach-Object {
        $stats = $_.Group.Segundos | Measure-Object -Average -Minimum -Maximum -StandardDeviation

        [pscustomobject]@{
            Ambiente             = $_.Name
            Iteracoes            = $_.Group.Count
            MediaSegundos        = [math]::Round($stats.Average, 2)
            DesvioPadraoSegundos = [math]::Round($stats.StandardDeviation, 2)
            MinimoSegundos       = [math]::Round($stats.Minimum, 2)
            MaximoSegundos       = [math]::Round($stats.Maximum, 2)
        }
    } | Format-Table -AutoSize
}

function Get-FasterEnvironment {
    param(
        [Parameter(Mandatory)][double]$SecondsA,
        [Parameter(Mandatory)][double]$SecondsB
    )

    if ($SecondsA -le $SecondsB) {
        $faster = 'A (NTFS)'
        $fasterTime = $SecondsA
        $slowerTime = $SecondsB
    } else {
        $faster = 'B (ReFS)'
        $fasterTime = $SecondsB
        $slowerTime = $SecondsA
    }

    $percentFaster = if ($slowerTime -eq 0) { 0 } else { [math]::Round((($slowerTime - $fasterTime) / $slowerTime) * 100, 2) }

    return [pscustomobject]@{
        Faster        = $faster
        PercentFaster = $percentFaster
    }
}

function Write-BenchmarkConclusion {
    param(
        [Parameter(Mandatory)][object[]]$Samples
    )

    $warmupA = ($Samples | Where-Object { $_.Ambiente -eq 'A (NTFS)' -and $_.Rodada -eq 'Warmup' }).Segundos
    $warmupB = ($Samples | Where-Object { $_.Ambiente -eq 'B (ReFS)' -and $_.Rodada -eq 'Warmup' }).Segundos
    $warmupResult = Get-FasterEnvironment -SecondsA $warmupA -SecondsB $warmupB

    $medicoes = $Samples | Where-Object { $_.Rodada -ne 'Warmup' }
    $mediaA = ($medicoes | Where-Object { $_.Ambiente -eq 'A (NTFS)' } | Measure-Object Segundos -Average).Average
    $mediaB = ($medicoes | Where-Object { $_.Ambiente -eq 'B (ReFS)' } | Measure-Object Segundos -Average).Average
    $medicoesResult = Get-FasterEnvironment -SecondsA $mediaA -SecondsB $mediaB

    Write-Host ''
    Write-Host "Warmup: $($warmupResult.Faster) foi $($warmupResult.PercentFaster)% mais rapido." -ForegroundColor Blue
    Write-Host "Medicoes: $($medicoesResult.Faster) foi $($medicoesResult.PercentFaster)% mais rapido." -ForegroundColor Blue
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

    Write-Host "Ambiente A (NTFS): $envAPath" -ForegroundColor Blue
    Write-Host "Ambiente B (ReFS): $envBPath" -ForegroundColor Blue

    Write-Stage 'Configurando o ambiente de build'

    Initialize-BuildConfiguration -ProjectRoot $envAPath -ConfigCommand $ConfigCommand -AutoRunToolPath $AutoRunToolPath -CapturedEnvFile $CapturedEnvFilePath

    Write-Stage 'Executando benchmark'

    $benchmarkResult = Invoke-Benchmark -EnvAPath $envAPath -EnvBPath $envBPath -Iterations $Iterations -BuildCommand $BuildCommand -ResultsFolder $ResultsFolderPath -ShowBuildOutput:$ShowBuildOutput

    Write-Stage 'Resultados'

    Show-BenchmarkSummary -Samples $benchmarkResult.Samples
    Write-BenchmarkConclusion -Samples $benchmarkResult.Samples
}
catch {
    Write-BenchmarkError -Stage $script:CurrentStage -ErrorRecord $_
    Invoke-EmergencyCleanup -AutoRunToolPath $AutoRunToolPath -CapturedEnvFile $CapturedEnvFilePath
    exit 1
}
