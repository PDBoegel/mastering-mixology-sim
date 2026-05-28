$ErrorActionPreference = "Continue"
$Rscript = "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:R_ENABLE_JIT = "0"
$env:MIX_TARGET = "61050,52550,70500"

$policies = @(
    "two_either_top2_bot",
    "meta_lenient_recommended",
    "meta_lenient_d20_b10_h05",
    "meta_lenient_d30_b10_h05",
    "meta_lenient_d20_b20_h05",
    "meta_lenient_d50_b20_h05"
)

# Wipe any stale chunks for these.
foreach ($pol in $policies) {
    Get-ChildItem (Join-Path $ProjectDir "results\policy_${pol}_c*.rds") -ErrorAction SilentlyContinue | Remove-Item -Force
}

for ($attempt = 1; $attempt -le 4; $attempt++) {
    Write-Host "`n=== attempt $attempt ==="
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
    Write-Host "needed: $($needed.Count)"

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
    $ok = 0
    foreach ($j in $jobs) {
        $out = Receive-Job -Job $j
        if (($out | Where-Object { $_ -match "done:" }).Count -gt 0) { $ok++ }
        Remove-Job $j
    }
    Write-Host "  landed $ok / $($needed.Count)"
}

Write-Host "`n=== summary ==="
& $Rscript "mixology_sim.R" "summarize" `
    (Join-Path $ProjectDir "results") `
    (Join-Path $ProjectDir "mixology_results.png") `
    (Join-Path $ProjectDir "mixology_summary.csv") 2>&1 | Select-Object -Last 50
