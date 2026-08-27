@echo off
rem ============================================================
rem  RedirecionarCachePacotes.cmd
rem
rem  Equivalente em CMD puro das funcoes Initialize-PackageCacheRedirection
rem  e Set-MavenRepoLocal do UmBenchmark.ps1: redireciona os caches
rem  de pacotes (npm, Deno, Yarn, Maven) para dentro do projeto, em
rem  .cache-pacotes\, em vez de usar os caches globais do usuario.
rem
rem  USO:
rem     RedirecionarCachePacotes.cmd [caminho-do-projeto]
rem     (se omitido, usa o diretorio atual)
rem
rem  IMPORTANTE: rode este .cmd diretamente no terminal (ou com
rem  "call"), NUNCA via "cmd /c RedirecionarCachePacotes.cmd" ou
rem  "start" - as variaveis de ambiente precisam sobreviver na
rem  sessao atual do CMD, e um processo filho perde tudo ao sair.
rem
rem  A substituicao de -Dmaven.repo.local dentro de MAVEN_OPTS
rem  (quando ja existente) usa um JScript gerado na hora e
rem  executado via cscript, espelhando com precisao a logica de
rem  Set-MavenRepoLocal (evita parsing fragil de regex em batch puro).
rem ============================================================

if "%~1"=="" (
    set "_UMB_PROJECT=%CD%"
) else (
    set "_UMB_PROJECT=%~f1"
)

set "_UMB_CACHE_ROOT=%_UMB_PROJECT%\.cache-pacotes"
set "_UMB_NPM=%_UMB_CACHE_ROOT%\npm"
set "_UMB_DENO=%_UMB_CACHE_ROOT%\deno"
set "_UMB_MAVEN=%_UMB_CACHE_ROOT%\maven"
set "_UMB_YARN=%_UMB_CACHE_ROOT%\yarn"

for %%D in ("%_UMB_NPM%" "%_UMB_DENO%" "%_UMB_MAVEN%" "%_UMB_YARN%") do (
    if not exist "%%~D" mkdir "%%~D" >nul 2>&1
)

set "NPM_CONFIG_CACHE=%_UMB_NPM%"
set "DENO_DIR=%_UMB_DENO%"
set "YARN_CACHE_FOLDER=%_UMB_YARN%"

call :SetMavenRepoLocal "%_UMB_MAVEN%"

echo.
echo Cache de pacotes redirecionado para: %_UMB_CACHE_ROOT%
echo   NPM_CONFIG_CACHE   = %NPM_CONFIG_CACHE%
echo   DENO_DIR           = %DENO_DIR%
echo   YARN_CACHE_FOLDER  = %YARN_CACHE_FOLDER%
echo   MAVEN_OPTS         = %MAVEN_OPTS%
echo.

set "_UMB_PROJECT="
set "_UMB_CACHE_ROOT="
set "_UMB_NPM="
set "_UMB_DENO="
set "_UMB_MAVEN="
set "_UMB_YARN="
goto :eof

rem ------------------------------------------------------------
rem :SetMavenRepoLocal <RepoPath>
rem Equivalente a Set-MavenRepoLocal do PowerShell:
rem   - Se MAVEN_OPTS ja tem -Dmaven.repo.local=..., substitui so
rem     esse trecho (aceita valor entre aspas ou sem espacos).
rem   - Se MAVEN_OPTS esta vazio, define do zero.
rem   - Caso contrario, concatena ao que ja existe.
rem Toda a logica mora no JScript gerado abaixo; o .cmd so aciona.
rem ------------------------------------------------------------
:SetMavenRepoLocal
set "_UMB_JS=%TEMP%\umb_setmvn_%RANDOM%%RANDOM%.js"

echo var Q = String.fromCharCode(34^); >"%_UMB_JS%"
echo var shell = WScript.CreateObject('WScript.Shell'^); >>"%_UMB_JS%"
echo var current = shell.Environment('PROCESS'^)('MAVEN_OPTS'^); >>"%_UMB_JS%"
echo var repoPath = WScript.Arguments(0^); >>"%_UMB_JS%"
echo var prefix = '-Dmaven.repo.local='; >>"%_UMB_JS%"
echo var flag = prefix + Q + repoPath + Q; >>"%_UMB_JS%"
echo var result; >>"%_UMB_JS%"
echo if (!current^) { >>"%_UMB_JS%"
echo   result = flag; >>"%_UMB_JS%"
echo } else { >>"%_UMB_JS%"
echo   var idx = current.indexOf(prefix^); >>"%_UMB_JS%"
echo   if (idx === -1^) { >>"%_UMB_JS%"
echo     result = current + ' ' + flag; >>"%_UMB_JS%"
echo   } else { >>"%_UMB_JS%"
echo     var rest = current.substring(idx + prefix.length^); >>"%_UMB_JS%"
echo     var endIdx; >>"%_UMB_JS%"
echo     if (rest.charAt(0^) === Q^) { >>"%_UMB_JS%"
echo       var closeIdx = rest.indexOf(Q, 1^); >>"%_UMB_JS%"
echo       endIdx = (closeIdx === -1^) ? rest.length : closeIdx + 1; >>"%_UMB_JS%"
echo     } else { >>"%_UMB_JS%"
echo       var spaceIdx = rest.indexOf(' '^); >>"%_UMB_JS%"
echo       endIdx = (spaceIdx === -1^) ? rest.length : spaceIdx; >>"%_UMB_JS%"
echo     } >>"%_UMB_JS%"
echo     result = current.substring(0, idx^) + flag + rest.substring(endIdx^); >>"%_UMB_JS%"
echo   } >>"%_UMB_JS%"
echo } >>"%_UMB_JS%"
echo WScript.Echo(result^); >>"%_UMB_JS%"

set "_UMB_RESULT="
for /f "delims=" %%R in ('cscript //nologo "%_UMB_JS%" "%~1" 2^>nul') do set "_UMB_RESULT=%%R"

del /f /q "%_UMB_JS%" >nul 2>&1
set "_UMB_JS="

rem "if defined" nao expande o VALOR da variavel para comparar, so
rem verifica se ela existe - isso e proposital: %MAVEN_OPTS% pode
rem conter aspas, e usa-las dentro de "if "%X%"==""" ou de um bloco
rem ( ... ) corrompe o parsing do CMD quando ha aspas embutidas.
if defined _UMB_RESULT goto :SetMavenRepoLocal_Apply

echo [AVISO] Nao foi possivel calcular MAVEN_OPTS via cscript (WSH/JScript indisponivel?). MAVEN_OPTS nao foi alterado - defina manualmente se necessario. 1>&2
goto :eof

:SetMavenRepoLocal_Apply
set "MAVEN_OPTS=%_UMB_RESULT%"
set "_UMB_RESULT="
goto :eof
