# UmBenchmark (PowerShell 7)

Projeto de uso unico, com fluxo direto e sem burocracia.

## Requisitos

- PowerShell 7+

## Estrutura

- UmBenchmark.ps1 - Script principal
- build.ps1 - Atalho opcional para executar o script principal

## Como usar

No terminal, dentro da pasta do projeto:

pwsh ./UmBenchmark.ps1

Com parametros:

pwsh ./UmBenchmark.ps1 -Iterations 10 -SleepMs 50

Opcional usando build:

pwsh ./build.ps1 -Iterations 10 -SleepMs 50
