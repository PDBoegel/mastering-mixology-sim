# Run two_plus_bn @ multiple targets, write results into the matching
# results_<target> dirs so re-summarizing each later picks it up.

$Rscript = "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:R_ENABLE_JIT = "0"

$targets = @(
    @{ Dir = "results_real_target";  Mix = "45138,39220,52684" },
    @{ Dir = "results_30_30_50";     Mix = "30000,30000,50000" },
    @{ Dir = "results_50_30_50";     Mix = "50000,30000,50000" },
    @{ Dir = "results_30_0_30_v2";   Mix = "30000,0,30000" },
    @{ Dir = "results_61_53_71";     Mix = "61050,52550,70500" }
)

foreach ($t in $targets) {
    $dir = Join-Path $ProjectDir $t.Dir
    $mix = $t.Mix
    Write-Host "`n=== $($t.Dir)  (MIX_TARGET=$mix) ==="

    # Wipe any prior two_plus_bn chunks so the rerun starts clean.
    Get-ChildItem (Join-Path $dir "policy_two_plus_bn_c*.rds") -ErrorAction SilentlyContinue | Remove-Item -Force

    $jobs = @()
    for ($c = 1; $c -le 10; $c++) {
        $outPath = Join-Path $dir "policy_two_plus_bn_c$c.rds"
        $jobs += Start-Job -ScriptBlock {
            param($R, $WD, $Out, $Seed, $Mix)
            Set-Location $WD
            $env:R_ENABLE_JIT = "0"
            $env:MIX_TARGET = $Mix
            & $R "mixology_sim.R" "chunk" "two_plus_bn" 100 $Out $Seed 2>&1
            "EXIT:$LASTEXITCODE"
        } -ArgumentList $Rscript, $ProjectDir, $outPath, $c, $mix
        # Throttle to 4 in flight
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge 4) {
            Start-Sleep -Milliseconds 200
        }
    }
    $jobs | Wait-Job | Out-Null
    foreach ($j in $jobs) {
        $out = Receive-Job -Job $j
        $line = ($out | Where-Object { $_ -match "done:" } | Select-Object -First 1)
        if ($line) { Write-Host "  $line" }
        else { Write-Host "  CHUNK FAILED: $($out -join ' | ')" }
        Remove-Job -Job $j
    }
    $count = (Get-ChildItem (Join-Path $dir "policy_two_plus_bn_c*.rds")).Count
    Write-Host "  -> $count / 10 chunks written"
}

Write-Host "`n=== Summarizing each target ==="
foreach ($t in $targets) {
    $dir = Join-Path $ProjectDir $t.Dir
    Write-Host "`n--- $($t.Dir) ---"
    & $Rscript "mixology_sim.R" "summarize" $dir (Join-Path $ProjectDir "summary_$($t.Dir).png") (Join-Path $ProjectDir "summary_$($t.Dir).csv") 2>&1 | Select-Object -Last 28
}
