#requires -Version 7.0
[CmdletBinding()]
param(
    [int]$Iterations = 5,
    [int]$SleepMs = 100
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot/UmBenchmark.ps1" -Iterations $Iterations -SleepMs $SleepMs
