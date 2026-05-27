# Mastering Mixology — Strategy Simulator

A Monte-Carlo simulator that evaluates order-submission policies for the
**Mastering Mixology** minigame in Old School RuneScape. The headline
output is an **adaptive meta-strategy** that minimizes potions brewed to
hit a chosen set of resin targets; that strategy is implemented in
the [Mastering Mixology plugin
fork](https://github.com/PDBoegel/mastering-mixology/tree/reward-tracking-multi-select)
as the *Recommended-Potion Highlight* feature.

**The full write-up is in [`STRATEGY.md`](STRATEGY.md).** That document
explains the problem, the simulator, every policy we tested, the threshold
sweep, the beam-search verification, and the plugin-integration
pseudocode.

## Highlight findings

* The optimal strategy depends on the *shape* of the target deficits. No
  single static policy wins everywhere.
* For targets with one colour modestly dominant (e.g. the standard
  "earn every non-pack reward" target, ~61k mox / 53k aga / 71k lye), an
  **adaptive meta-policy** beats every static policy by ~130 potions
  (1.7 %) and beats greedy by ~1 300 potions (14.9 %).
* Beam search at K = 200 000 was used to bound the true optimum from
  below. On the 5 test sequences it matched the best static policy
  exactly, which is strong empirical evidence the meta is near-optimal.
* The recommended thresholds (`t_dual_in = 20 %`, `t_dual_out = 25 %`,
  `t_balanced_in = 10 %`, `t_balanced_out = 15 %`) sit in the middle of a
  broad optimum region — the choice is not fragile.

## Repository layout

| File | Purpose |
|---|---|
| `STRATEGY.md` | Full write-up: problem, simulator, all policies, sweep, plugin pseudocode |
| `mixology_sim.R` | Simulator core: data, triggers, fallbacks, `make_policy`, `simulate_one`, `make_meta_policy`, the policy registry |
| `beam_optimum.R` | Beam-search verifier; matches the policy result on tested seeds |
| `true_optimum.R` | Exhaustive forward-DP attempt (intractable in pure R; kept for reference) |
| `paste_analysis.R` | Compute paste consumption (mox/aga/lye) for a given policy |
| `policy_decisions.R` | Log per-turn decisions for a given policy |
| `optimizer_analysis.R` | Log per-turn decisions for the 1-step lookahead heuristic |
| `aggregate_decisions.R`, `aggregate_opt_decisions.R` | Read per-trial decision logs, summarize patterns by hand signature |
| `run_all.ps1` | Run the full leaderboard (every policy) at a given target |
| `run_chunks.ps1` | Per-policy chunked runner (works around an R 4.5.2 / Windows segfault under long loops) |
| `run_meta_sweep.ps1`, `run_meta_sweep2.ps1`, `retry_meta.ps1`, `run_two_plus_bn_sweep.ps1` | Threshold-grid runners for the meta-policy and the bottleneck-aware static policy |

## Running

```bash
# Default target = the user's remaining reward cost
Rscript mixology_sim.R all 1000

# Custom target via env var (comma-separated mox,aga,lye)
MIX_TARGET=61050,52550,70500 Rscript mixology_sim.R all 1000

# A specific policy + chunk (used by the PowerShell orchestrators)
Rscript mixology_sim.R chunk meta_recommended 200 results/policy_meta_recommended_c1.rds 1

# Aggregate a results directory
Rscript mixology_sim.R summarize results mixology_results.png mixology_summary.csv
```

Recommended chunked execution via PowerShell:

```powershell
$env:MIX_TARGET = "61050,52550,70500"
.\run_all.ps1 -Trials 1000 -MaxParallel 4
```

## Requirements

* **R 4.5.2** (other recent versions likely work; tested only on 4.5.2 /
  Windows). The instability noted in the scripts is specific to that
  version's bytecode JIT on Windows.
* **Packages** — `tibble`, `dplyr`, `purrr`, `ggplot2`, `fastmap`. The
  simulator file uses `suppressPackageStartupMessages` so any missing
  package fails clearly.
* **PowerShell 5.1+** for the chunked orchestrators.

## Caveats

* The simulator assumes orders are sampled independently with the
  published level-81 weights `5/5/5/4/4/4/4/4/4/3` for
  `MMM/AAA/LLL/MMA/MML/AAM/ALA/MLL/ALL/MAL`. Verified against the OSRS
  wiki; behaviour matches in-game observation.
* Paste is treated as unlimited because the player metric we optimize is
  potions brewed, not paste consumed. `paste_analysis.R` reports paste
  consumption after the fact for a given policy.
* Digweed (a random doubling of one potion's resin gain) is omitted because
  it's a multiplicative scalar across every policy and doesn't change
  rankings.
* R 4.5.2 on Windows has a JIT bug that intermittently corrupts
  closure-captured function objects under long tight loops. We disable the
  JIT (`R_ENABLE_JIT=0`) in the orchestrators and call `gc()` per trial.
  Chunked execution + automatic retry on failure handles the remaining
  randomness.

## Licence

MIT.
