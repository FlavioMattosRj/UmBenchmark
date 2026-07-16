#requires -Version 7.0

[CmdletBinding()]
param(
    [int]$Iterations = 5,
    [int]$SleepMs = 100
)

$ErrorActionPreference = 'Stop'

Write-Host "Benckmark de Builds entre partição NTFS e Dev Drive" -ForegroundColor Cyan
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "Iteracoes: $Iterations"

$samples = for ($i = 1; $i -le $Iterations; $i++) {
    $elapsed = Measure-Command {
        Start-Sleep -Milliseconds $SleepMs
    }

    [pscustomobject]@{
        Iteration = $i
        Millis    = [math]::Round($elapsed.TotalMilliseconds, 2)
    }
}

$avg = ($samples.Millis | Measure-Object -Average).Average
$min = ($samples.Millis | Measure-Object -Minimum).Minimum
$max = ($samples.Millis | Measure-Object -Maximum).Maximum

Write-Host ''
$samples | Format-Table -AutoSize

Write-Host ''
Write-Host "Resumo:" -ForegroundColor Green
Write-Host ("Media:   {0:N2} ms" -f $avg)
Write-Host ("Minimo:  {0:N2} ms" -f $min)
Write-Host ("Maximo:  {0:N2} ms" -f $max)
