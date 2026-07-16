#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigCommand
)

Write-Host "Comando: $ConfigCommand"

Invoke-Expression $ConfigCommand
