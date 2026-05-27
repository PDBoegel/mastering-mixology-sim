$ErrorActionPreference = "Stop"
$Rscript = "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:R_ENABLE_JIT = "0"
$env:MIX_TARGET = "61050,52550,70500"

$policies = @(
    "meta_d05_b02_h05", "meta_d05_b05_h05",
    "meta_d10_b02_h05", "meta_d10_b05_h05", "meta_d10_b05_h10",
    "meta_d15_b05_h05",
    "meta_d20_b05_h05", "meta_d20_b10_h05",
    "meta_d30_b10_h05"
)

foreach ($pol in $policies) {
    Write-Host "`n=== $pol ==="
    # Clear any prior chunks for this policy
    Get-ChildItem (Join-Path $ProjectDir "results\policy_${pol}_c*.rds") -ErrorAction SilentlyContinue | Remove-Item -Force

    $jobs = @()
    for ($c = 1; $c -le 10; $c++) {
        $outPath = Join-Path $ProjectDir "results\policy_${pol}_c$c.rds"
        $jobs += Start-Job -ScriptBlock {
            param($R, $WD, $P, $Out, $Seed, $Mix)
            Set-Location $WD
            $env:R_ENABLE_JIT = "0"
            $env:MIX_TARGET = $Mix
            & $R "mixology_sim.R" "chunk" $P 100 $Out $Seed 2>&1
            "EXIT:$LASTEXITCODE"
        } -ArgumentList $Rscript, $ProjectDir, $pol, $outPath, $c, $env:MIX_TARGET
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge 4) {
            Start-Sleep -Milliseconds 200
        }
    }
    $jobs | Wait-Job | Out-Null
    $okCount = 0
    foreach ($j in $jobs) {
        $out = Receive-Job -Job $j
        $line = ($out | Where-Object { $_ -match "done:" } | Select-Object -First 1)
        if ($line) { $okCount++ }
        Remove-Job -Job $j
    }
    $files = (Get-ChildItem (Join-Path $ProjectDir "results\policy_${pol}_c*.rds")).Count
    Write-Host "  -> $files / 10 chunks written"
}

Write-Host "`n=== Final summary ==="
& $Rscript "mixology_sim.R" "summarize" `
    (Join-Path $ProjectDir "results") `
    (Join-Path $ProjectDir "meta_sweep.png") `
    (Join-Path $ProjectDir "meta_sweep.csv") 2>&1 | Select-Object -Last 40
