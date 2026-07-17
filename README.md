# UmBenchmark

Ferramenta em PowerShell 7 para comparar o desempenho de build de um projeto Java (Maven) rodando em dois sistemas de arquivos diferentes — tipicamente uma partição **NTFS** convencional e uma partição **ReFS** (Dev Drive) — mantendo tudo o mais isolado e controlado possível, para que a única variável real entre as duas execuções seja o sistema de arquivos.

## Por que isso existe

Dev Drive (ReFS) promete builds mais rápidos em projetos com muito I/O de arquivos pequenos (Node, Maven, .NET). Mas "promete" não é dado — é preciso medir. O UmBenchmark automatiza o processo de:

1. Pegar o código-fonte de um projeto (sem nunca tocar na origem).
2. Criar duas cópias idênticas — uma em cada sistema de arquivos.
3. Configurar o ambiente de build (variáveis de ambiente, ferramentas) uma única vez.
4. Rodar o mesmo build repetidamente, alternando entre os dois ambientes.
5. Medir, comparar e apresentar os resultados — incluindo quantos % mais rápido um ambiente foi em relação ao outro.

## Requisitos

- PowerShell 7+
- Maven (`mvn`) e Java instalados e no `PATH` (para o build de exemplo/padrão)
- Git instalado e no `PATH` (usado se `-Source` não for informado)
- Duas raízes de disco já existentes — uma em cada sistema de arquivos a comparar

## Estrutura do projeto

```text
UmBenchmark.ps1        Script principal (tudo em funções de propósito único + orquestração no final)
Ferramentas/            Utilitários auxiliares usados durante a execução
  CriarVariaveisEAbrirConsole.java   Ferramenta de configuracao padrao (exemplo/mock)
  DescarregarVariaveis.cmd           Despeja variaveis de ambiente do console de configuracao
  DesligarAutoRun.cmd                Kill-switch manual para o AutoRun do cmd.exe
  MVN.BAT                            Wrapper de exemplo do mvn (nao usado pelo fluxo padrao atual)
  ExecutarComandoConfiguracao.ps1    Testa um -ConfigCommand isoladamente, sem rodar o pipeline todo
Resultados/             CSVs gerados a cada execucao (nao versionado)
```

## Como funciona, passo a passo

Quando você roda `UmBenchmark.ps1`, ele passa por estágios nomeados (anunciados no console), sempre nesta ordem:

### 1. Validando parâmetros e origem

- Confirma que as duas raízes de disco (`-NtfsRoot` e `-RefsRoot`) existem.
- Resolve a origem do projeto (`-Source`): se você não informar nada, a ferramenta clona automaticamente um projeto de exemplo (veja [Fonte padrão](#fonte-padrão-quando--source-não-é-informado)).
- Aceita a origem como uma **pasta** ou um **arquivo ZIP**. Se for ZIP, detecta se ele tem uma única pasta envolvendo tudo (usa o nome dela) ou arquivos soltos na raiz (usa o nome do próprio ZIP, sem extensão).
- **A origem nunca é modificada.** Tudo o que acontece depois trabalha em cópias.

### 2. Criando diretórios de build

- Copia (ou expande, no caso de ZIP) a origem para dentro de cada uma das duas raízes, criando **Ambiente A** (NTFS) e **Ambiente B** (ReFS) — duas cópias completas e independentes do projeto, com o mesmo nome de pasta.
- Cada cópia é feita do zero a cada execução (a pasta de destino é limpa antes).

### 3. Configurando o ambiente de build

- Executa, uma única vez, uma ferramenta de configuração (`-ConfigCommand`) a partir da raiz do **Ambiente A** — o lugar de onde ela deve enxergar o projeto.
- Essa ferramenta é qualquer coisa que prepare o ambiente de build (variáveis de ambiente, toolchain) e, ao final, abra um console `cmd.exe` já configurado.
- O UmBenchmark captura essas variáveis de ambiente automaticamente: registra temporariamente o `DescarregarVariaveis.cmd` como `AutoRun` do `cmd.exe`, o que faz qualquer console aberto durante essa janela despejar seu ambiente em `Ferramentas\VarAmb.txt`. O arquivo é então lido, as variáveis são aplicadas ao processo PowerShell atual (você vê no console quais são **novas** e quais foram **alteradas**), o `AutoRun` é revertido ao estado original, e o console de configuração é fechado automaticamente.
- Se algo falhar nessa etapa, `VarAmb.txt` é preservado (não apagado) para depuração.

### 4. Executando benchmark

- **Warmup**: uma execução do build em cada ambiente (A depois B), só para preencher caches de dependências (Maven, npm, Deno) — sem essa etapa, o primeiro build medido seria injustamente mais lento.
- **Iterações medidas**: `-Iterations` rodadas, cada uma alternando um build em A e um em B, com o tempo de cada uma cronometrado.
- Antes de cada build, o cache de pacotes (`.cache-pacotes/{npm,deno,maven}`) é redirecionado para dentro da própria cópia do projeto — assim os artefatos baixados ficam no mesmo sistema de arquivos sendo medido, e não em um cache global compartilhado que mascararia a diferença.
- O comando de build (`-BuildCommand`) é executado de verdade a partir da pasta do projeto. Por padrão, é um build limpo (`mvn clean package`), forçando recompilação total a cada iteração.

### 5. Resultados

- Todas as medições (warmup **e** iterações) são listadas individualmente no console e salvas em `Resultados\Resultados_AAAAMMDD_HHMMSS.csv`.
- É calculada e exibida a média, desvio padrão, mínimo e máximo por ambiente — **excluindo o warmup** desse cálculo (ele existe só para aquecer o cache, não para ser comparado).
- Por fim, uma conclusão indica qual ambiente foi mais rápido e por quantos %, separadamente para o warmup e para as iterações medidas.

## Fonte padrão (quando `-Source` não é informado)

Se você não passar `-Source`, o script usa um projeto de exemplo:

1. Procura `Ferramentas\FamTask.zip`. Se existir, usa direto (rápido, sem rede).
2. Se não existir, clona `https://github.com/FlavioMattosRj/FamTask.git` para `Ferramentas\FamTask`, empacota o conteúdo (sem a pasta `.git`) em `Ferramentas\FamTask.zip`, e apaga a pasta clonada — deixando só o ZIP para as próximas execuções.

Esse ZIP fica em `Ferramentas/` mas **não é versionado** (está no `.gitignore`), já que é apenas um artefato de conveniência local.

## Parâmetros

| Parâmetro | Obrigatório | Padrão | Descrição |
| --- | --- | --- | --- |
| `-NtfsRoot` | Sim | — | Raiz de disco no sistema de arquivos NTFS onde o Ambiente A será criado. |
| `-RefsRoot` | Sim | — | Raiz de disco no sistema de arquivos ReFS/Dev Drive onde o Ambiente B será criado. |
| `-Source` | Não | `''` (vazio) | Pasta ou arquivo `.zip` com o código-fonte do projeto. Nunca é modificado. Se vazio, usa a [fonte padrão](#fonte-padrão-quando--source-não-é-informado). |
| `-ConfigCommand` | Não | `java "Ferramentas\CriarVariaveisEAbrirConsole.java"` | Comando que prepara o ambiente de build e abre um console configurado, a partir do qual as variáveis de ambiente são capturadas. |
| `-Iterations` | Não | `5` | Número de rodadas **medidas** (além do warmup, que é sempre uma execução por ambiente). |
| `-BuildCommand` | Não | `mvn clean package` | Comando de build executado, de verdade, dentro da pasta do projeto em cada ambiente. |
| `-ShowBuildOutput` | Não | `$false` | Se presente, ecoa no terminal a saída completa do comando de build. Por padrão, a saída fica oculta e só os tempos/mensagens do próprio script aparecem. |

## Exemplos de uso

Rodar com o projeto de exemplo (clona automaticamente na primeira vez), 5 iterações padrão:

```powershell
pwsh ./UmBenchmark.ps1 -NtfsRoot C:\ -RefsRoot D:\
```

Rodar com um projeto próprio, fornecido como ZIP, com 10 iterações:

```powershell
pwsh ./UmBenchmark.ps1 -NtfsRoot C:\ -RefsRoot D:\ -Source D:\Projetos\MeuApp.zip -Iterations 10
```

Rodar com um projeto próprio já expandido em pasta, vendo a saída completa do Maven:

```powershell
pwsh ./UmBenchmark.ps1 -NtfsRoot C:\ -RefsRoot D:\ -Source D:\Projetos\MeuApp -ShowBuildOutput
```

Trocar o goal do Maven (ex.: sem `clean`, para medir build incremental):

```powershell
pwsh ./UmBenchmark.ps1 -NtfsRoot C:\ -RefsRoot D:\ -BuildCommand 'mvn package'
```

Usar uma ferramenta de configuração de ambiente diferente da padrão:

```powershell
pwsh ./UmBenchmark.ps1 -NtfsRoot C:\ -RefsRoot D:\ -ConfigCommand 'C:\Ferramentas\ConfigurarVisualStudio.bat'
```

## Ferramentas auxiliares (`Ferramentas/`)

- **CriarVariaveisEAbrirConsole.java**: ferramenta de configuração de exemplo — define duas variáveis de ambiente e abre um console `cmd.exe` já com elas. Serve de modelo para uma ferramenta real (ex.: um `vcvarsall.bat` ou script de setup de toolchain).
- **DescarregarVariaveis.cmd**: usado internamente pelo mecanismo de captura de variáveis; não precisa ser chamado manualmente.
- **DesligarAutoRun.cmd**: remove manualmente o `AutoRun` do `cmd.exe` (`HKCU\Software\Microsoft\Command Processor`), para os casos raros em que uma execução anterior tenha sido interrompida antes de reverter esse valor sozinha.
- **ExecutarComandoConfiguracao.ps1**: roda um `-ConfigCommand` isoladamente (mostra a linha executada e a saída), útil para testar um candidato antes de usá-lo no benchmark completo.
