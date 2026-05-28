$ErrorActionPreference = "Continue"
$Rscript = "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:R_ENABLE_JIT = "0"
$env:MIX_TARGET = "30000,20000,30000"

$policies = @(
    "meta_recommended", "meta_lenient_recommended",
    "meta_tied_01", "meta_tied_05", "meta_tied_10",
    "two_dual_bot", "two_either_top2_bot",
    "two_dual_tied_01_bot", "two_dual_tied_05_bot", "two_dual_tied_10_bot"
)

for ($attempt = 1; $attempt -le 4; $attempt++) {
    $needed = @()
    foreach ($pol in $policies) {
        for ($c = 1; $c -le 10; $c++) {
            $path = Join-Path $ProjectDir "results\policy_${pol}_c$c.rds"
            if (-not (Test-Path $path)) {
                $needed += [pscustomobject]@{ Pol = $pol; Chunk = $c }
            }
        }
    }
    if ($needed.Count -eq 0) { break }
    Write-Host "attempt $attempt needs $($needed.Count)"

    $jobs = @()
    foreach ($n in $needed) {
        $seed = ($attempt * 100) + ($n.Chunk * 7) + ($needed.IndexOf($n))
        $outPath = Join-Path $ProjectDir "results\policy_$($n.Pol)_c$($n.Chunk).rds"
        $jobs += Start-Job -ScriptBlock {
            param($R, $WD, $P, $Out, $Seed, $Mix)
            Set-Location $WD
            $env:R_ENABLE_JIT = "0"
            $env:MIX_TARGET = $Mix
            & $R "mixology_sim.R" "chunk" $P 100 $Out $Seed 2>&1
            "EXIT:$LASTEXITCODE"
        } -ArgumentList $Rscript, $ProjectDir, $n.Pol, $outPath, $seed, $env:MIX_TARGET
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge 4) {
            Start-Sleep -Milliseconds 200
        }
    }
    $jobs | Wait-Job | Out-Null
    foreach ($j in $jobs) { Receive-Job $j | Out-Null; Remove-Job $j }
}

Write-Host "`n=== summary @ 30k/20k/30k ==="
& $Rscript "mixology_sim.R" "summarize" `
    (Join-Path $ProjectDir "results") `
    (Join-Path $ProjectDir "mixology_results.png") `
    (Join-Path $ProjectDir "mixology_summary.csv") 2>&1 | Select-Object -Last 25
