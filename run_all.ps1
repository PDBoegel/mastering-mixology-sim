# Orchestrate the Mastering Mixology simulator: one Rscript process per
# policy (works around R 4.5.2 / Windows instability under long loops),
# then a final summarize pass that joins everything and writes the plot.
#
# Usage:
#   .\run_all.ps1                            # default 1000 trials per policy
#   .\run_all.ps1 -Trials 10000
#   .\run_all.ps1 -Trials 5000 -MaxParallel 4

param(
    [int]$Trials = 1000,
    [int]$MaxParallel = 4
)

$ErrorActionPreference = "Stop"
$Rscript = "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SimScript = Join-Path $ProjectDir "mixology_sim.R"
$ResultsDir = Join-Path $ProjectDir "results"

# R 4.5.2's JIT compiler has a bytecode bug that corrupts closure-captured
# function objects under long tight loops (segfault or "unused arguments"
# error after thousands of iterations). Disabling JIT fixes it.
$env:R_ENABLE_JIT = "0"

if (Test-Path $ResultsDir) {
    Remove-Item "$ResultsDir\policy_*.rds" -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path $ResultsDir | Out-Null
}

# Pull the policy names out of the R file so we don't duplicate the list.
$Policies = & $Rscript -e "source('$($SimScript.Replace('\','/'))'); cat(names(default_policies), sep='\n')" 2>$null
$Policies = $Policies | Where-Object { $_ -and $_ -notmatch '^\s*$' }
Write-Host "Policies: $($Policies -join ', ')"
Write-Host "Trials per policy: $Trials"
Write-Host "Max parallel: $MaxParallel`n"

$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

function Invoke-PolicyBatch {
    param([string[]]$ToRun, [int]$Trials, [int]$MaxParallel)
    $jobs = @()
    foreach ($pol in $ToRun) {
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxParallel) {
            Start-Sleep -Milliseconds 200
        }
        $outPath = Join-Path $script:ResultsDir "policy_$pol.rds"
        Write-Host "  -> launching $pol"
        $mixTarget = $env:MIX_TARGET
        $jobs += Start-Job -ScriptBlock {
            param($Rscript, $SimScript, $Pol, $Trials, $OutPath, $MixTarget)
            $env:R_ENABLE_JIT = "0"
            if ($MixTarget) { $env:MIX_TARGET = $MixTarget }
            & $Rscript $SimScript "single" $Pol $Trials $OutPath 2>&1
            "EXIT_CODE:$LASTEXITCODE"
        } -ArgumentList $script:Rscript, $script:SimScript, $pol, $Trials, $outPath, $mixTarget
    }
    $jobs | Wait-Job | Out-Null
    foreach ($j in $jobs) {
        $out = Receive-Job -Job $j
        Write-Host ($out -join "`n")
        Remove-Job -Job $j
    }
}

# Retry loop: any policy whose RDS file is missing gets re-attempted up to
# MaxAttempts times. R 4.5.2 occasionally aborts a process mid-run with no
# error written to stdout.
$MaxAttempts = 5
$attempt = 1
$remaining = $Policies
while ($remaining.Count -gt 0 -and $attempt -le $MaxAttempts) {
    Write-Host "`n=== Attempt $attempt -- running $($remaining.Count) policies ==="
    Invoke-PolicyBatch -ToRun $remaining -Trials $Trials -MaxParallel $MaxParallel
    $remaining = @($Policies | Where-Object {
        -not (Test-Path (Join-Path $ResultsDir "policy_$_.rds"))
    })
    if ($remaining.Count -gt 0) {
        Write-Host "Still missing: $($remaining -join ', ')"
    }
    $attempt++
}

$totalSw.Stop()
if ($remaining.Count -gt 0) {
    Write-Warning "Gave up after $MaxAttempts attempts. Missing: $($remaining -join ', ')"
}
Write-Host "`nAll attempts done in $([Math]::Round($totalSw.Elapsed.TotalSeconds,1))s. Summarizing..."

$pngPath = Join-Path $ProjectDir "mixology_results.png"
$csvPath = Join-Path $ProjectDir "mixology_summary.csv"
& $Rscript $SimScript "summarize" $ResultsDir $pngPath $csvPath
