#requires -Version 5.1

<#
.SYNOPSIS
    Copia uma instalacao do Eclipse para a raiz de uma unidade Dev Drive e
    ajusta os arquivos .ini do launcher para carregarem os JARs a partir da
    copia no Dev Drive, mantendo o Eclipse.exe (loader) e o proprio .ini fora
    do Dev Drive.

.DESCRIPTION
    Cenario: por politica de seguranca o Eclipse nao e "instalado" no disco do
    Dev Drive (E: por exemplo). A solucao e manter o loader nativo
    (Eclipse.exe / Eclipse.ini) na particao original e apontar, dentro do
    .ini, as linhas de execucao para a copia da instalacao no Dev Drive.

    O script faz:

      1) Copia a instalacao inteira para  <DevDrive>\<NomeDestino>  (robocopy).
      2) Salva copia dos arquivos .ini originais:
           - <arquivo>.ini.orig            (uma unica vez, nunca sobrescrito)
           - <arquivo>.ini.<timestamp>.bak (a cada execucao)
      3) Reescreve, nos .ini, as linhas que apontam para JARs / pastas de
         execucao, trocando "pasta local" pelo caminho correspondente no
         Dev Drive.

    O formato do eclipse.ini (um argumento por linha) e estavel nas versoes
    dos ultimos ~5 anos (2020..2025). Diretivas de caminho tratadas:

      Valor na linha SEGUINTE a diretiva:
        -startup            -> JAR do org.eclipse.equinox.launcher
        --launcher.library  -> fragmento nativo do launcher (pasta ou .dll)
        -vm                 -> somente quando aponta para dentro da instalacao
                               (ex.: JRE JustJ embarcada em plugins\...)

      Inline (mesma linha):
        -javaagent:<jar>[=opcoes]
        -agentpath:<lib>[=opcoes]

      Com -Agressivo, tambem trata (sempre so quando o caminho aponta para
      dentro da instalacao de origem):
        Valor na linha seguinte:
          -configuration  -install  -dev  -keyring
          -plugincustomization  --launcher.ini
        Inline:
          -Xbootclasspath/a:  -Xbootclasspath/p:  -Xbootclasspath:
          -D<chave>= com chave de area/caminho:
            osgi.install.area  osgi.configuration.area
            osgi.sharedConfiguration.area  osgi.instance.area
            osgi.instance.area.default  osgi.user.area  osgi.syspath
            osgi.framework  eclipse.p2.data.area  java.library.path
            eclipse.pluginCustomization
        Arquivo extra:
          configuration\config.ini  (chaves osgi.framework e *.area)

    NUNCA sao alterados: valores com tokens @ (ex.: @user.home, @config.dir,
    @none, @noDefault), variaveis de ambiente (%VAR% ou ${VAR}), caminhos UNC
    (\\servidor\...) e caminhos absolutos que ja apontam para fora da
    instalacao de origem.

.PARAMETER Origem
    Pasta com a instalacao do Eclipse. Padrao: a pasta atual (se for um
    Eclipse valido).

.PARAMETER DevDrive
    Letra da unidade Dev Drive de destino. Padrao: E

.PARAMETER NomeDestino
    Nome da pasta a criar na raiz do Dev Drive. Padrao: o nome da pasta de
    origem.

.PARAMETER Alvo
    Quais .ini reescrever:
      Original (padrao) -> os .ini que ficam junto do loader, na origem
      Copia             -> os .ini dentro da copia no Dev Drive
      Ambos             -> os dois conjuntos

.PARAMETER Agressivo
    Amplia o conjunto de diretivas tratadas (ver DESCRIPTION).

.PARAMETER Force
    Se a pasta de destino ja existir e nao estiver vazia, espelha por cima
    (robocopy /MIR). Sem este switch, o script aborta nesse caso.

.PARAMETER Simular
    Mostra o que seria feito sem copiar arquivos nem gravar .ini.

.EXAMPLE
    .\RedirecionarEclipseParaDevDrive.ps1 -Origem 'C:\eclipse' -DevDrive E

.EXAMPLE
    cd C:\Tools\eclipse ; .\RedirecionarEclipseParaDevDrive.ps1 -Alvo Ambos -Agressivo

.NOTES
    - Feche o Eclipse antes de rodar (arquivos abertos fazem o robocopy
      pular itens e falhar).
    - Gravar na raiz de E:\ pode exigir console com privilegios de
      administrador, dependendo da ACL da unidade.
#>

[CmdletBinding()]
param(
    [string]$Origem = (Get-Location).Path,
    [string]$DevDrive = 'E',
    [string]$NomeDestino = '',
    [ValidateSet('Original', 'Copia', 'Ambos')]
    [string]$Alvo = 'Original',
    [switch]$Agressivo,
    [switch]$Force,
    [switch]$Simular
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Saida
# ---------------------------------------------------------------------------

function Write-Passo { param([string]$Texto) Write-Host "==> $Texto" -ForegroundColor Cyan }
function Write-Info  { param([string]$Texto) Write-Host "    $Texto" -ForegroundColor Blue }
function Write-Ok    { param([string]$Texto) Write-Host "    $Texto" -ForegroundColor Green }
function Write-Aviso { param([string]$Texto) Write-Host "    [AVISO] $Texto" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Deteccao da instalacao
# ---------------------------------------------------------------------------

function Get-CaminhoAbsoluto {
    param([Parameter(Mandatory)][string]$Caminho)

    $p = $Caminho.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $p)) { throw "Caminho nao encontrado: $p" }
    $completo = (Resolve-Path -LiteralPath $p).ProviderPath
    return ([System.IO.Path]::GetFullPath($completo)).TrimEnd('\')
}

function Get-InisDeLauncher {
    # .ini de launcher na raiz da instalacao: os que tem um .exe irmao de
    # mesmo nome-base, ou que contenham as diretivas -startup /
    # --launcher.library em linha propria.
    param([Parameter(Mandatory)][string]$Raiz)

    $resultado = New-Object System.Collections.Generic.List[string]

    Get-ChildItem -LiteralPath $Raiz -Filter *.ini -File -ErrorAction SilentlyContinue | ForEach-Object {
        $ini = $_
        $base = [System.IO.Path]::GetFileNameWithoutExtension($ini.Name)
        $exeIrmao = Join-Path $Raiz ($base + '.exe')
        $temExe = Test-Path -LiteralPath $exeIrmao -PathType Leaf

        $conteudo = ''
        try { $conteudo = [System.IO.File]::ReadAllText($ini.FullName) } catch { }
        $temMarcador = $conteudo -match '(?m)^\s*(-startup|--launcher\.library)\s*$'

        if ($temExe -or $temMarcador) { $resultado.Add($ini.FullName) }
    }

    return $resultado.ToArray()
}

function Test-InstalacaoEclipse {
    param([Parameter(Mandatory)][string]$Raiz)

    if (-not (Test-Path -LiteralPath $Raiz -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Raiz 'plugins') -PathType Container)) { return $false }

    return (@(Get-InisDeLauncher -Raiz $Raiz).Count -gt 0)
}

function Test-EhDevDrive {
    param([Parameter(Mandatory)][string]$RaizUnidade)

    try {
        $saida = & fsutil devdrv query $RaizUnidade 2>$null
        if ($LASTEXITCODE -eq 0 -and (($saida -join ' ') -match 'Dev Drive')) { return $true }
    } catch { }
    return $false
}

# ---------------------------------------------------------------------------
# Copia
# ---------------------------------------------------------------------------

function Invoke-CopiaInstalacao {
    param(
        [Parameter(Mandatory)][string]$Origem,
        [Parameter(Mandatory)][string]$Destino,
        [switch]$Espelhar
    )

    $modo = if ($Espelhar) { '/MIR' } else { '/E' }
    $rcArgs = @(
        $Origem, $Destino, $modo,
        '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/R:1', '/W:1', '/MT:16',
        '/NFL', '/NDL', '/NP', '/NJH', '/NJS'
    )

    Write-Info "robocopy `"$Origem`" `"$Destino`" $modo ..."
    & robocopy @rcArgs | Out-Null
    $codigo = $LASTEXITCODE

    # robocopy: 0..7 = sucesso ; >= 8 = falha real
    if ($codigo -ge 8) {
        throw "robocopy falhou (codigo $codigo) ao copiar para $Destino. O Eclipse esta aberto? Ha permissao de escrita na unidade?"
    }
    Write-Ok "Copia concluida (robocopy codigo $codigo)."
}

# ---------------------------------------------------------------------------
# Reescrita de caminhos
# ---------------------------------------------------------------------------

function Convert-ValorParaDevDrive {
    # Recebe um valor de caminho vindo de um .ini e devolve o caminho
    # reescrito para o Dev Drive, ou $null se a linha nao deve mudar.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Valor,
        [Parameter(Mandatory)][string]$RaizOrigem,
        [Parameter(Mandatory)][string]$RaizDestino
    )

    $v = $Valor.Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }

    # Prefixo file: (com 0..3 barras) - preservado no retorno.
    $prefixoFile = ''
    $m = [regex]::Match($v, '^(file:/{0,3})(.*)$', 'IgnoreCase')
    if ($m.Success -and $m.Groups[1].Value -ne '') {
        $prefixoFile = $m.Groups[1].Value
        $v = $m.Groups[2].Value
    }

    if ($v.StartsWith('@'))      { return $null }   # @user.home, @config.dir, @none, ...
    if ($v -match '%[^%]+%')     { return $null }   # %VAR%
    if ($v -match '\$\{[^}]+\}') { return $null }   # ${VAR}
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }

    $norm = $v.Replace('/', '\')
    $novo = $null

    if ($norm -match '^[A-Za-z]:\\') {
        # Absoluto com letra de unidade.
        $ro = $RaizOrigem.TrimEnd('\')
        $normLc = $norm.ToLowerInvariant()
        $roLc = $ro.ToLowerInvariant()
        if ($normLc -eq $roLc -or $normLc.StartsWith($roLc + '\')) {
            $resto = $norm.Substring($ro.Length).TrimStart('\')
            $novo = if ($resto) { Join-Path $RaizDestino $resto } else { $RaizDestino }
        }
        else {
            return $null   # aponta para fora da origem - preservar
        }
    }
    elseif ($norm.StartsWith('\\')) {
        return $null       # UNC - preservar
    }
    else {
        # Relativo a raiz da instalacao.
        if ($norm.StartsWith('.\')) { $norm = $norm.Substring(2) }
        $resto = $norm.TrimStart('\')
        if (-not $resto) { return $null }
        $novo = Join-Path $RaizDestino $resto
    }

    if (-not $novo) { return $null }

    # Em URLs file: mantem barras normais; caso contrario usa barras do
    # Windows (o launcher nativo aceita as duas, mas "\" e o mais seguro).
    if ($prefixoFile -ne '') { $novo = $novo.Replace('\', '/') }

    $final = $prefixoFile + $novo
    if ($final -eq $Valor.Trim()) { return $null }
    return $final
}

function Test-ExisteNaOrigem {
    param(
        [Parameter(Mandatory)][string]$Valor,
        [Parameter(Mandatory)][string]$RaizOrigem
    )

    $v = $Valor.Trim().Trim('"')
    $v = ($v -replace '^(?i)file:/{0,3}', '')
    if ($v -match '^[A-Za-z]:\\' -or $v.StartsWith('\\')) {
        return (Test-Path -LiteralPath $v)
    }
    if ($v.StartsWith('@') -or $v -match '%[^%]+%' -or $v -match '\$\{[^}]+\}') {
        return $true   # token dinamico - nao da para verificar, nao alertar
    }
    return (Test-Path -LiteralPath (Join-Path $RaizOrigem ($v -replace '/', '\')))
}

function Update-IniEclipse {
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [Parameter(Mandatory)][string]$RaizOrigem,
        [Parameter(Mandatory)][string]$RaizDestino,
        [switch]$Agressivo,
        [switch]$Simular
    )

    $nomeArquivo = [System.IO.Path]::GetFileName($Caminho)
    $ehConfigIni = ($nomeArquivo -ieq 'config.ini')

    $textoOriginal = [System.IO.File]::ReadAllText($Caminho)
    $terminaComQuebra = $textoOriginal.EndsWith("`n")

    $linhas = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($textoOriginal -split "`r?`n")) { $linhas.Add($l) }
    if ($terminaComQuebra -and $linhas.Count -gt 0 -and $linhas[$linhas.Count - 1] -eq '') {
        $linhas.RemoveAt($linhas.Count - 1)
    }

    # Diretivas cujo valor esta na PROXIMA linha (nomes em minusculo).
    $dirProximaLinha = New-Object System.Collections.Generic.List[string]
    $dirProximaLinha.AddRange([string[]]@('-startup', '--launcher.library', '-vm'))
    if ($Agressivo) {
        $dirProximaLinha.AddRange([string[]]@(
                '-configuration', '-install', '-dev', '-keyring',
                '-plugincustomization', '--launcher.ini'
            ))
    }

    # Chaves de propriedade que carregam caminhos (somente -Agressivo).
    $chavesArea = @(
        'osgi.install.area', 'osgi.configuration.area', 'osgi.sharedConfiguration.area',
        'osgi.instance.area', 'osgi.instance.area.default', 'osgi.user.area',
        'osgi.syspath', 'osgi.framework', 'eclipse.p2.data.area',
        'java.library.path', 'eclipse.pluginCustomization'
    )

    $mudancas = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $linhas.Count; $i++) {
        $linha = $linhas[$i]
        $trim = $linha.Trim()
        if ($trim -eq '' -or $trim.StartsWith('#')) { continue }

        # (1) diretiva isolada + valor na linha seguinte
        if (-not $ehConfigIni -and ($dirProximaLinha -contains $trim.ToLowerInvariant()) -and ($i + 1) -lt $linhas.Count) {
            $valor = $linhas[$i + 1]
            $novo = Convert-ValorParaDevDrive -Valor $valor -RaizOrigem $RaizOrigem -RaizDestino $RaizDestino
            if ($null -ne $novo -and $novo -ne $valor) {
                if (-not (Test-ExisteNaOrigem -Valor $valor -RaizOrigem $RaizOrigem)) {
                    Write-Aviso "$nomeArquivo : referencia nao encontrada na origem: $valor"
                }
                $mudancas.Add(("{0}`n      de  : {1}`n      para: {2}" -f $trim, $valor, $novo))
                if (-not $Simular) { $linhas[$i + 1] = $novo }
            }
            continue
        }

        # (2) tokens inline
        $prefixosAgente = @('-javaagent:', '-agentpath:')
        $prefixosLista = @()
        if ($Agressivo) { $prefixosLista = @('-Xbootclasspath/a:', '-Xbootclasspath/p:', '-Xbootclasspath:') }

        $tratou = $false

        foreach ($pfx in $prefixosAgente) {
            if ($trim.StartsWith($pfx, [System.StringComparison]::OrdinalIgnoreCase)) {
                $resto = $trim.Substring($pfx.Length)
                $eq = $resto.IndexOf('=')
                $cam = if ($eq -ge 0) { $resto.Substring(0, $eq) } else { $resto }
                $opc = if ($eq -ge 0) { $resto.Substring($eq) } else { '' }
                $novo = Convert-ValorParaDevDrive -Valor $cam -RaizOrigem $RaizOrigem -RaizDestino $RaizDestino
                if ($null -ne $novo) {
                    if (-not (Test-ExisteNaOrigem -Valor $cam -RaizOrigem $RaizOrigem)) {
                        Write-Aviso "$nomeArquivo : referencia nao encontrada na origem: $cam"
                    }
                    $linhaNova = $pfx + $novo + $opc
                    $mudancas.Add(("{0}`n      de  : {1}`n      para: {2}" -f $pfx.TrimEnd(':'), $linha, $linhaNova))
                    if (-not $Simular) { $linhas[$i] = $linhaNova }
                    $tratou = $true
                }
                break
            }
        }
        if ($tratou) { continue }

        foreach ($pfx in $prefixosLista) {
            if ($trim.StartsWith($pfx, [System.StringComparison]::OrdinalIgnoreCase)) {
                $partes = $trim.Substring($pfx.Length) -split ';'
                $mudou = $false
                for ($k = 0; $k -lt $partes.Count; $k++) {
                    $n = Convert-ValorParaDevDrive -Valor $partes[$k] -RaizOrigem $RaizOrigem -RaizDestino $RaizDestino
                    if ($null -ne $n) { $partes[$k] = $n; $mudou = $true }
                }
                if ($mudou) {
                    $linhaNova = $pfx + ($partes -join ';')
                    $mudancas.Add(("{0}`n      de  : {1}`n      para: {2}" -f $pfx.TrimEnd(':'), $linha, $linhaNova))
                    if (-not $Simular) { $linhas[$i] = $linhaNova }
                    $tratou = $true
                }
                break
            }
        }
        if ($tratou) { continue }

        # (3) propriedades de area:  -D<chave>=<valor>  ou  <chave>=<valor> (config.ini)
        if ($Agressivo) {
            $mp = [regex]::Match($trim, '^(?<pfx>-D)?(?<key>[A-Za-z0-9_.]+)=(?<val>.*)$')
            if ($mp.Success -and ($chavesArea -contains $mp.Groups['key'].Value)) {
                if (-not $ehConfigIni -and $mp.Groups['pfx'].Value -ne '-D') { continue }
                $partes = $mp.Groups['val'].Value -split ';'
                $mudou = $false
                for ($k = 0; $k -lt $partes.Count; $k++) {
                    $n = Convert-ValorParaDevDrive -Valor $partes[$k] -RaizOrigem $RaizOrigem -RaizDestino $RaizDestino
                    if ($null -ne $n) { $partes[$k] = $n; $mudou = $true }
                }
                if ($mudou) {
                    $linhaNova = $mp.Groups['pfx'].Value + $mp.Groups['key'].Value + '=' + ($partes -join ';')
                    $mudancas.Add(("{0}`n      de  : {1}`n      para: {2}" -f $mp.Groups['key'].Value, $linha, $linhaNova))
                    if (-not $Simular) { $linhas[$i] = $linhaNova }
                }
                continue
            }
        }
    }

    if ($mudancas.Count -eq 0) {
        Write-Info "$nomeArquivo : nenhuma linha de caminho para ajustar."
        return 0
    }

    foreach ($c in $mudancas) { Write-Ok ("$nomeArquivo : $c") }

    if (-not $Simular) {
        $saida = [string]::Join("`r`n", $linhas.ToArray())
        if ($terminaComQuebra) { $saida += "`r`n" }
        $utf8SemBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Caminho, $saida, $utf8SemBom)
    }

    return $mudancas.Count
}

function Backup-Ini {
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [switch]$Simular
    )

    $orig = "$Caminho.orig"
    $bak = "$Caminho.{0}.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss')

    if (Test-Path -LiteralPath $orig) {
        Write-Info "backup original ja existe: $([System.IO.Path]::GetFileName($orig))"
    }
    else {
        Write-Info "backup original: $([System.IO.Path]::GetFileName($orig))"
        if (-not $Simular) { Copy-Item -LiteralPath $Caminho -Destination $orig }
    }

    Write-Info "backup datado  : $([System.IO.Path]::GetFileName($bak))"
    if (-not $Simular) { Copy-Item -LiteralPath $Caminho -Destination $bak }
}

# ---------------------------------------------------------------------------
# Fluxo principal
# ---------------------------------------------------------------------------

Write-Passo "Validando a instalacao de origem"

$RaizOrigem = Get-CaminhoAbsoluto -Caminho $Origem
if (-not (Test-InstalacaoEclipse -Raiz $RaizOrigem)) {
    throw "Nao parece uma instalacao do Eclipse (faltam a pasta 'plugins' e/ou um .ini de launcher): $RaizOrigem"
}
Write-Info "Origem : $RaizOrigem"

$letra = $DevDrive.Trim().Trim('"').TrimEnd('\', '/', ':')
if ($letra.Length -ne 1 -or $letra -notmatch '^[A-Za-z]$') {
    throw "Informe a unidade Dev Drive como uma unica letra, ex.: -DevDrive E"
}
$raizUnidade = ($letra.ToUpperInvariant() + ':\')
if (-not (Test-Path -LiteralPath $raizUnidade)) { throw "Unidade nao encontrada: $raizUnidade" }

if ([string]::IsNullOrWhiteSpace($NomeDestino)) {
    $NomeDestino = Split-Path -Leaf $RaizOrigem
}
$RaizDestino = (Join-Path $raizUnidade $NomeDestino).TrimEnd('\')

if ($RaizOrigem.ToLowerInvariant() -eq $RaizDestino.ToLowerInvariant()) {
    throw "Origem e destino apontam para a mesma pasta: $RaizDestino"
}

Write-Info "Destino: $RaizDestino"
if (-not (Test-EhDevDrive -RaizUnidade $raizUnidade)) {
    Write-Aviso "$raizUnidade nao foi identificada como Dev Drive (continuando mesmo assim)."
}
if ($Simular) { Write-Aviso "Modo -Simular: nada sera copiado nem gravado." }

# --- (1) copia -------------------------------------------------------------

Write-Passo "Copiando a instalacao para o Dev Drive"

$destinoExiste = Test-Path -LiteralPath $RaizDestino -PathType Container
$destinoNaoVazio = $destinoExiste -and `
    ((Get-ChildItem -LiteralPath $RaizDestino -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)

if ($Simular) {
    $modoTxt = if ($destinoNaoVazio) { '/MIR' } else { '/E' }
    Write-Info "[simular] robocopy `"$RaizOrigem`" `"$RaizDestino`" $modoTxt"
}
elseif ($destinoNaoVazio -and -not $Force) {
    throw "O destino ja existe e nao esta vazio: $RaizDestino  (use -Force para espelhar por cima)"
}
else {
    if (-not $destinoExiste) { New-Item -ItemType Directory -Path $RaizDestino -Force | Out-Null }
    Invoke-CopiaInstalacao -Origem $RaizOrigem -Destino $RaizDestino -Espelhar:($destinoNaoVazio)
}

# --- (2) e (3) .ini ------------------------------------------------------

Write-Passo "Ajustando os arquivos .ini"

$inisOrigem = @(Get-InisDeLauncher -Raiz $RaizOrigem)
if ($Agressivo) {
    $cfgOrig = Join-Path $RaizOrigem 'configuration\config.ini'
    if (Test-Path -LiteralPath $cfgOrig) { $inisOrigem += $cfgOrig }
}

$alvos = New-Object System.Collections.Generic.List[psobject]
foreach ($ini in $inisOrigem) {
    $rel = $ini.Substring($RaizOrigem.Length).TrimStart('\')

    if ($Alvo -eq 'Original' -or $Alvo -eq 'Ambos') {
        $alvos.Add([pscustomobject]@{ Caminho = $ini; Rotulo = "origem\$rel" })
    }
    if ($Alvo -eq 'Copia' -or $Alvo -eq 'Ambos') {
        $destIni = Join-Path $RaizDestino $rel
        if (Test-Path -LiteralPath $destIni) {
            $alvos.Add([pscustomobject]@{ Caminho = $destIni; Rotulo = "destino\$rel" })
        }
        elseif (-not $Simular) {
            Write-Aviso "esperava um .ini na copia mas ele nao existe: $destIni"
        }
    }
}

if ($alvos.Count -eq 0) { throw "Nenhum arquivo .ini de launcher encontrado para ajustar." }

$totalMudancas = 0
foreach ($item in $alvos) {
    Write-Passo "  $($item.Rotulo)"
    Backup-Ini -Caminho $item.Caminho -Simular:$Simular
    $totalMudancas += Update-IniEclipse -Caminho $item.Caminho `
        -RaizOrigem $RaizOrigem -RaizDestino $RaizDestino `
        -Agressivo:$Agressivo -Simular:$Simular
}

# --- resumo --------------------------------------------------------------

Write-Passo "Concluido"
Write-Info "Instalacao copiada para : $RaizDestino"
Write-Info "Arquivos .ini tratados  : $($alvos.Count)  (alvo: $Alvo)"
Write-Info "Linhas reescritas       : $totalMudancas"
if ($Simular) { Write-Aviso "Modo -Simular: nenhuma alteracao foi gravada." }
else { Write-Ok "O loader continua na origem; a execucao agora usa os JARs em $RaizDestino." }
