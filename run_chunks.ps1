# Run problem policies in 5 chunks of 200 trials each (across parallel
# processes). R 4.5.2 crashes on a single 1000-trial run of these policies
# but small chunks complete reliably.

param(
    [string[]]$Policies = @("two_plus_lye", "mal_or_multi"),
    [int]$ChunkSize = 200,
    [int]$NumChunks = 5,
    [int]$MaxParallel = 4
)

$ErrorActionPreference = "Stop"
$Rscript = "C:\Program Files\R\R-4.5.2\bin\Rscript.exe"
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SimScript = Join-Path $ProjectDir "mixology_sim.R"
$ResultsDir = Join-Path $ProjectDir "results"

foreach ($pol in $Policies) {
    Remove-Item (Join-Path $ResultsDir "policy_${pol}.rds") -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $ResultsDir "policy_${pol}_c*.rds") -ErrorAction SilentlyContinue
}

$jobs = @()
foreach ($pol in $Policies) {
    foreach ($c in 1..$NumChunks) {
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxParallel) {
            Start-Sleep -Milliseconds 200
        }
        $outPath = Join-Path $ResultsDir "policy_${pol}_c${c}.rds"
        Write-Host "  -> launching $pol chunk $c"
        $mixTarget = $env:MIX_TARGET
        $jobs += Start-Job -ScriptBlock {
            param($Rscript, $WorkDir, $SimScript, $Pol, $N, $OutPath, $Seed, $MixTarget)
            Set-Location $WorkDir
            $env:R_ENABLE_JIT = "0"
            if ($MixTarget) { $env:MIX_TARGET = $MixTarget }
            & $Rscript $SimScript "chunk" $Pol $N $OutPath $Seed 2>&1
            "EXIT:$LASTEXITCODE"
        } -ArgumentList $Rscript, $ProjectDir, $SimScript, $pol, $ChunkSize, $outPath, $c, $mixTarget
    }
}

$jobs | Wait-Job | Out-Null
foreach ($j in $jobs) {
    $out = Receive-Job -Job $j
    Write-Host ($out -join "`n")
    Remove-Job -Job $j
}

Write-Host "`n--- Chunk results ---"
Get-ChildItem (Join-Path $ResultsDir "policy_*_c*.rds") | Format-Table Name, Length
