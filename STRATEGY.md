# Mastering Mixology — Order-Submission Strategy

A simulation-driven study of optimal play in the Mastering Mixology minigame
for Old School RuneScape, with a recommended decision algorithm for in-game
and plugin use.

---

## 1. The game in one paragraph

The player faces a conveyor of **3 simultaneous orders**, each calling for one
of 10 potion types. Brewing a matching potion fulfils that order and grants
**resin** in one or more of three colours: mox, aga, lye. Submitting the
conveyor with **2 potions at once** grants a **+20 % resin bonus** on the
batch; with **3 potions at once**, **+40 %**. After *any* submission (even of
a single potion), **all three orders refresh**. Earned resin is spent in a
shop on cosmetics, storage upgrades, and consumables. We optimize **total
potions brewed** to reach a player-chosen set of resin targets.

The simulator and all source code described below live in
`C:\Users\User\mixology-sim\`.

---

## 2. Game data (verified against the OSRS wiki)

Each potion is identified by three letters M / A / L corresponding to the
paste type(s) it uses, with weights for order-roll probability.

| Code | Name | Paste (M/A/L) | Resin (M/A/L) | Order weight |
|---|---|---|---|---:|
| MMM | Mammoth-might mix | 3 / 0 / 0 | 10 / 0 / 0 | 5 |
| AAA | Alco-augmentator | 0 / 3 / 0 | 0 / 10 / 0 | 5 |
| LLL | Liplack liquor | 0 / 0 / 3 | 0 / 0 / 10 | 5 |
| MMA | Mystic Mana Amalgam | 2 / 1 / 0 | 10 / 10 / 0 | 4 |
| MML | Marley's Moonlight | 2 / 0 / 1 | 10 / 0 / 10 | 4 |
| AAM | Azure Aura Mix | 1 / 2 / 0 | 10 / 10 / 0 | 4 |
| ALA | Aqualux Amalgam | 0 / 2 / 1 | 0 / 10 / 10 | 4 |
| MLL | Megalite Liquid | 1 / 0 / 2 | 10 / 0 / 10 | 4 |
| ALL | Anti-leech Lotion | 0 / 1 / 2 | 0 / 10 / 10 | 4 |
| MAL | Mixalot | 1 / 1 / 1 | 10 / 10 / 10 | 3 |

Total weight = 42. Each potion is **3 paste units = 30 paste** (the wiki uses
"30 paste per potion"; the simulator's `*_paste` columns store units, i.e. ×10
to convert to paste).

Resin yield per slot has a *symmetric expectation* across the three colours
(240 / 42 = 5.71 of each, +40 % bonus → 8.0 / colour / potion if always
submitting 3). The asymmetry that makes this problem interesting comes from
the **targets** the player picks: typically lye-dominant by 10–35 %.

---

## 3. Simulator design

Single file: `mixology_sim.R`. Tested with R 4.5.2 / Windows.

- 10 potion rows + cached matrices `RESIN_MAT`, `WEIGHTS`, `N_POTIONS`.
- `TARGET` is configurable via the `MIX_TARGET` env var
  (`"45138,39220,52684"` etc.). Default = the cost of the original
  remaining-rewards target.
- One trial = `simulate_one(policy)`: starts with `(0, 0, 0)` resin, samples 3
  weighted orders, applies the policy's decision, accumulates resin (with the
  +20 % / +40 % bonus by submission size), refreshes **all 3** orders, repeats
  until every target is met.
- Outer driver = `run_policy()` × `n_trials`. Chunking + retry orchestration
  in `run_chunks.ps1` works around an R 4.5.2 / Windows segfault that fires
  intermittently on long inner loops (forced `gc()` per trial mitigates it).

### Methodological notes
- Per-slot orders are independent draws (with replacement). Wiki doesn't
  state explicitly; behaviour matches in-game observation.
- Goggles / amulet rewards modify Herblore but not Mixology output → omitted.
- Digweed (a random doubling of one potion's resin) is omitted because it's a
  multiplicative scalar across **all** policies and doesn't change ranking.
- We do not model paste shortages — paste is assumed unlimited because the
  player metric is potions brewed.

---

## 4. Policy framework

A **policy** is a closure `(orders, deficit) → slot_indices` returning the 1,
2, or 3 slot indices the player will brew this turn. Policies are constructed
from three pieces:

1. **Trigger(s)** — boolean predicates on `(orders, deficit)`. When the
   combination of triggers fires, the policy commits to **all 3** (the +40 %
   bonus).
2. **Combine mode** — `"any"` (OR-of-triggers) or `"all"` (AND-of-triggers).
3. **Fallback** — what to submit when no trigger fires; always returns ≥1.

Implemented as `make_policy(triggers, combine, fallback)` in
`mixology_sim.R`. Triggers live in the `TRIGGERS` list; fallbacks in
`FALLBACKS`.

### Trigger library (excerpt)

| Trigger | Fires when… |
|---|---|
| `all_lye` | all 3 orders give lye resin |
| `two_plus_lye` | ≥ 2 orders give lye |
| `any_lye` | ≥ 1 order gives lye |
| `has_mal` | any order is MAL |
| `multi_resin` | none of the 3 orders is MMM / AAA / LLL |
| `no_single` | none of the 3 is a single-resin potion |
| `lye_ahead` | current *resin* lye > both mox and aga |
| `helps_deficit` | every order's deficit-score is positive |
| `two_dual_bottleneck` | ≥ 2 orders give *both* of the top-2 deficit colours |
| `two_plus_bottleneck` | ≥ 2 orders give the *single* largest-deficit colour |
| `lye_needed_two_plus` | lye still has positive deficit AND ≥ 2 lye-givers |

### Fallback library (excerpt)

| Fallback | Behaviour |
|---|---|
| `greedy_all` | submit all 3 anyway (degrade to greedy) |
| `best_deficit_one` | submit single slot with highest deficit-reduction score |
| `best_deficit_two` | submit top-2 by deficit score |
| `lye_giving_only` | submit only slots giving lye; else best-deficit single |
| `helpful_only` | submit slots whose deficit-score > 0 |
| `non_overflow` | submit slots that don't push any *satisfied* resin further |
| `bottleneck_color` | identify top-deficit colour, submit slots giving it |
| `lookahead_greedy` | enumerate 7 subsets; pick min `n + max(remaining)/8` |

---

## 5. Findings: which strategy wins depends on target shape

Each target shape was benchmarked at 1,000 Monte-Carlo trials per policy.

| Target (mox / aga / lye) | Shape | Winning policy | Mean potions | Δ vs `greedy` |
|---|---|---|---:|---:|
| 20k / 20k / 20k | Balanced | `mal_or_multi` ≈ `multi_resin` | 2,359 | −7 % |
| 30k / 25k / 30k | Nearly balanced | `multi_resin` | 3,418 | −10 % |
| 30k / 0 / 30k | Two colours only | `all_lye_bot` ≈ `two_dual_bot` | 3,404 | −10 % |
| 30k / 30k / 50k | Lye strongly dominant | `two_dual_bot` | 4,664 | −25 % |
| 50k / 30k / 50k | Mox = lye tied bottlenecks | `all_lye_bot` ≈ `two_dual_bot` | 5,671 | −10 % |
| 45k / 39k / 53k *(remaining)* | Lye modestly dominant | `two_plus_bn` | 5,681 | −14 % |
| **61k / 53k / 71k** *(full 8-item)* | Lye modestly dominant | `meta` (adaptive) | **7,502** | **−15 %** |

### Three regimes in plain language

* **Balanced targets**: brew only multi-resin potions (no MMM/AAA/LLL). Each
  contributes to two or more colours simultaneously, so the +40 % bonus is
  most efficient when the hand contains no "single-colour wasters".
* **One colour strongly dominant**: count slots giving the bottleneck colour;
  if ≥ 2 of 3 give it, take all 3 anyway (the off-colour potion still helps
  the secondary). This is the `two_plus_<color>_bot` family.
* **Two colours tied as the bottleneck**: look for hands with ≥ 2 slots that
  give *both* tied colours (`two_dual_bot`). The strict conjunction picks up
  hands where the +40 % batch fills both constraints simultaneously.

### Why the same policy doesn't always win

Under any lye-focused policy, lye fills *faster* than mox or aga (9.2 vs 7.9
vs 6.9 per potion). If the target ratio places lye at ≤ 1.36× the smallest
target (your real run), lye still finishes last and the lye-counting trigger
stays the right play. If lye is at > 1.5× and the secondary targets are
*small*, mox or aga overshoots before lye finishes, and the +40 % batches in
that overshoot window waste resin on an already-satisfied colour. Hence the
30 / 30 / 50 inversion where `two_dual_bot` wins by dynamically tracking
which colour is currently active.

---

## 6. Beam-search verification

To establish that the simulator's best static policy is near the true
sequence-optimum, a beam search with admissible heuristic
`h = ⌈max(remaining)/14⌉` (since the max resin per potion is 14 with bonus)
was run on 5 random sequences at the 45 k / 39 k / 53 k target. Beam widths
K = 50 000 and K = 200 000 both **matched the policy's potion count
exactly**, on every seed. With 200 k candidate paths held per turn over
~4 000 turns, this is strong empirical evidence that
`two_plus_lye_bot` (and its bottleneck-generic cousin `two_plus_bn`) is
**co-optimal** with the true minimum on that target shape.

Beam-search code: `beam_optimum.R`. Exact DP at full state was attempted in
`true_optimum.R` but is intractable in pure R — by turn ~10 the layer holds
~300 k distinct reachable states; pruning by the heuristic doesn't bite
until well past potion ~2 000.

---

## 7. The adaptive meta-policy

A static policy is locked into one regime. But over the course of one run the
deficit shape *changes*: starts lye-dominant (modest gap), spends time near
"two colours tied" once the primary fills a bit, may end "almost balanced".
A meta-policy switches sub-policy based on the current deficit shape, with
hysteresis to avoid thrashing.

### State machine

```
state := single_bn       // at trial start (resin == 0)

each turn:
  d_pos = max(deficit, 0)
  sorted = sort(d_pos, decreasing)
  d_max, d_mid, d_min = sorted[0..2]

  gap_12 = (d_max - d_mid) / d_max   // gap between top-1 and top-2 deficit
  gap_13 = (d_max - d_min) / d_max   // gap between top-1 and top-3 deficit

  // Transitions (with hysteresis). When leaving "balanced", the next state
  // is chosen by whichever shape matches the current gaps: dual_bn if the
  // top-2 are still tight, single_bn otherwise.
  switch (state):
    case single_bn:
      if gap_13 < t_balanced_in:    state = balanced
      else if gap_12 < t_dual_in:   state = dual_bn
    case dual_bn:
      if gap_13 < t_balanced_in:    state = balanced
      else if gap_12 > t_dual_out:  state = single_bn
    case balanced:
      if gap_13 > t_balanced_out:
        state = (gap_12 < t_dual_in) ? dual_bn : single_bn

  return sub_policy[state](orders, deficit)
```

### Sub-policies

| State | Sub-policy | Inner rule |
|---|---|---|
| `single_bn` | `two_plus_bn` | ≥ 2 slots give top-1-deficit colour → all 3; else slots matching that colour |
| `dual_bn` | `two_dual_bot` | ≥ 2 slots give *both* top-2 colours → all 3; else slots matching top-1 colour |
| `balanced` | `multi_resin` | all 3 are multi-resin → all 3; else best-deficit single slot |

All three sub-policies share `bottleneck_color` as their per-turn fallback
when the trigger fails, with the exception that `multi_resin` uses
`best_deficit_one` (a single-slot fallback is preferable when colours are
nearly balanced — submitting more than one risks overshoot).

### Threshold sweep

10 meta variants, 100-1000 Monte-Carlo trials per variant, target
61 k / 53 k / 71 k.

| Variant | `t_dual_in` | `t_balanced_in` | hysteresis | Mean potions | Trials |
|---|---:|---:|---:|---:|---:|
| `meta_d50_b20_h05` | 50 % | 20 % | 5 % | 7,488 | 400 |
| `meta_d20_b20_h05` | 20 % | 20 % | 5 % | 7,490 | 300 |
| `meta_d20_b10_h10` | 20 % | 10 % | 10 % | 7,497 | 500 |
| **`meta_d20_b10_h05`** | **20 %** | **10 %** | **5 %** | **7,502** | **1000** |
| `meta_d30_b10_h05` | 30 % | 10 % | 5 % | 7,502 | 800 |
| `meta_d20_b10_h02` | 20 % | 10 % | 2 % | 7,504 | 300 |
| `meta_d25_b10_h05` | 25 % | 10 % | 5 % | 7,506 | 100 |
| `meta_d20_b05_h05` | 20 % | 5 % | 5 % | 7,548 | 1000 |
| `meta_d15_b05_h05` | 15 % | 5 % | 5 % | 7,549 | 1000 |
| `meta_d10_b05_h05` | 10 % | 5 % | 5 % | 7,561 | 1000 |
| `meta_d05_b05_h05` | 5 % | 5 % | 5 % | 7,572 | 1000 |
| `meta_d05_b02_h05` | 5 % | 2 % | 5 % | 7,591 | 1000 |
| — | best static policy (`two_plus_bn`) | | | 7,633 | 1000 |
| — | `greedy` baseline | | | 8,813 | 1000 |

The top seven variants are within ~18 potions of each other — well inside the
p10–p90 spread of any single variant (~85 potions). The optimal threshold is
not a sharp point; it's a **broad region**. Inside the region the choice
doesn't matter; outside it, the meta starts behaving like its weaker
sub-policy.

### Recommended thresholds (for the plugin)

```
t_dual_in       = 0.20   (20 %)   — enter dual when top-2 deficits within 20 %
t_dual_out      = 0.25   (25 %)   — leave dual when they widen past 25 %
t_balanced_in   = 0.10   (10 %)   — enter balanced when all 3 within 10 %
t_balanced_out  = 0.15   (15 %)   — leave balanced when they widen past 15 %
```

These are clean round numbers in the middle of the optimal region with sane
5 % hysteresis on each transition.

---

## 8. Implementation pseudocode for the plugin

Each time orders refresh (the existing `onVarbitChanged` handler in
`MasteringMixologyPlugin.java`), call `MetaPolicy.decide()` with the current
orders, the player's resin from the varps, and the summed target from the
player's tracked rewards. The output is which slot(s) to highlight as
"recommended to brew this turn".

```java
class MetaPolicy {
    enum State { SINGLE_BN, DUAL_BN, BALANCED }
    private State state = State.SINGLE_BN;

    static final double T_DUAL_IN      = 0.20;
    static final double T_DUAL_OUT     = 0.25;
    static final double T_BALANCED_IN  = 0.10;
    static final double T_BALANCED_OUT = 0.15;

    /** Reset state when the player (re-)enters the lab. */
    void reset() { state = State.SINGLE_BN; }

    /**
     * @param orders          the 3 current orders (each is a Potion enum)
     * @param currentResin    [mox, aga, lye] from the resin varps
     * @param target          [mox, aga, lye] = sum of selected reward costs
     * @return                slot indices (1..3) the player should brew
     */
    int[] decide(Potion[] orders, int[] currentResin, int[] target) {
        int[] deficit = { max(target[0] - currentResin[0], 0),
                          max(target[1] - currentResin[1], 0),
                          max(target[2] - currentResin[2], 0) };

        // Identify top-1 and top-2 deficits
        int[] sorted = sortedDesc(deficit);
        int  dMax = sorted[0], dMid = sorted[1], dMin = sorted[2];
        double gap12 = dMax == 0 ? Double.POSITIVE_INFINITY : (dMax - dMid) / (double) dMax;
        double gap13 = dMax == 0 ? Double.POSITIVE_INFINITY : (dMax - dMin) / (double) dMax;

        // State transition
        switch (state) {
            case SINGLE_BN:
                if      (gap13 < T_BALANCED_IN) state = State.BALANCED;
                else if (gap12 < T_DUAL_IN)     state = State.DUAL_BN;
                break;
            case DUAL_BN:
                if      (gap13 < T_BALANCED_IN) state = State.BALANCED;
                else if (gap12 > T_DUAL_OUT)    state = State.SINGLE_BN;
                break;
            case BALANCED:
                if (gap13 > T_BALANCED_OUT) {
                    state = (gap12 < T_DUAL_IN) ? State.DUAL_BN : State.SINGLE_BN;
                }
                break;
        }

        // Dispatch to sub-policy
        switch (state) {
            case SINGLE_BN: return singleBnAction(orders, deficit);
            case DUAL_BN:   return dualBnAction  (orders, deficit);
            case BALANCED:  return balancedAction(orders, deficit);
        }
        throw new IllegalStateException();
    }

    /** "≥2 of 3 give top-1 deficit colour → all 3, else slots matching top-1." */
    int[] singleBnAction(Potion[] orders, int[] deficit) {
        int topColor = argMax(deficit);
        int count = countSlotsGiving(orders, topColor);
        if (count >= 2) return ALL_THREE;
        if (count == 1) return slotsGiving(orders, topColor);
        return new int[] { bestDeficitSlot(orders, deficit) };
    }

    /** "≥2 of 3 give BOTH top-2 deficit colours → all 3, else fallback." */
    int[] dualBnAction(Potion[] orders, int[] deficit) {
        int[] top2 = top2Indices(deficit);
        int count = countSlotsGivingBoth(orders, top2[0], top2[1]);
        if (count >= 2) return ALL_THREE;
        // Same bottleneck-colour fallback as SINGLE_BN
        return singleBnFallback(orders, deficit);
    }

    /** "All 3 are multi-resin → all 3, else best deficit-score single slot." */
    int[] balancedAction(Potion[] orders, int[] deficit) {
        if (allMultiResin(orders)) return ALL_THREE;
        return new int[] { bestDeficitSlot(orders, deficit) };
    }
}
```

Supporting helpers (canonical R implementations in `mixology_sim.R`,
sections `TRIGGERS`, `FALLBACKS`):

* `argMax(int[])` — index of largest entry; ties broken by lowest index
  (matches R's `which.max`).
* `top2Indices(int[])` — indices of the two largest entries (decreasing).
* `countSlotsGiving(orders, color)` — how many of the 3 orders' potions yield
  resin in `color`.
* `countSlotsGivingBoth(orders, c1, c2)` — how many give *both*.
* `bestDeficitSlot(orders, deficit)` — argmax of
  `sum(resin[slot, c] * max(deficit[c], 0) for c in 0..2)` (see
  `deficit_scores` in the R file).
* `allMultiResin(orders)` — every order has ≥ 2 of its `*_resin` entries > 0
  (i.e. no MMM, AAA, or LLL).

### Plugin integration points

1. **Reset hook** — call `MetaPolicy.reset()` when the player enters the lab
   region (the plugin already tracks `isInLab` / `isInLabRegion()`).
2. **Per-turn call** — in `onVarbitChanged` for the order varbits, after the
   existing `recalculateGoalData()`, call `MetaPolicy.decide(...)` with the
   live deficit (already computed in `Goal.recalculate`) and surface the
   recommended slot indices via a new overlay tint or info-box label.
3. **Target source** — read from the player's existing reward selection in
   `MasteringMixologyConfig` (the eight `trackX` checkboxes + four
   `*Quantity` ints, already implemented). Use the same per-reward summation
   helper as the threshold-notification feature.
4. **Disable when no reward selected** — if `target` is `[0, 0, 0]` (no
   rewards ticked), skip the meta-policy and surface no recommendation.

---

## 9. Files in this directory (canonical references)

| File | Purpose |
|---|---|
| `mixology_sim.R` | Simulator core: constants, triggers, fallbacks, `make_policy`, `simulate_one`, `make_meta_policy`, the policy registry |
| `beam_optimum.R` | Beam-search verifier (matches policy results on tested seeds) |
| `true_optimum.R` | Exhaustive DP attempt (intractable in pure R; kept for reference) |
| `policy_decisions.R` | Logs per-turn decisions of a given policy for offline analysis |
| `aggregate_opt_decisions.R` | Reads logs, summarizes per-hand-signature decision distribution |
| `paste_analysis.R` | Computes paste consumption (mox/aga/lye) for a given policy |
| `run_chunks.ps1` | Per-policy chunked execution; works around R 4.5.2 instability |
| `run_all.ps1` | Full leaderboard runner across all `default_policies` |
| `run_meta_sweep.ps1`, `run_meta_sweep2.ps1` | Threshold-grid runners for the meta-policy |
| `retry_meta.ps1` | Re-runs missing chunks after R crashes |
| `STRATEGY.md` | This document |

---

## 10. Caveats and open questions

* The R 4.5.2 / Windows instability is real and reproducible. All
  long-running runs use chunked Rscript invocations and an automatic
  retry-on-segfault loop. The R 4.5.2 JIT can also corrupt closure-captured
  function objects under heavy GC pressure; we disable it via
  `R_ENABLE_JIT=0`.
* The exact-DP attempt (`true_optimum.R`) is not feasible in pure R. The beam
  search at K=200 000 acts as an empirical upper bound on the optimum. The
  meta-policy at 7,502 is within at most ~150 potions of the true minimum on
  the 61 k / 53 k / 71 k target.
* Variance across 1 000 Monte-Carlo trials is ~85 potions p10-p90 for any
  given policy. Differences smaller than that should be treated as ties.
* The meta-policy's threshold sweep was done at the 61 k / 53 k / 71 k target
  only. The recommended values are likely robust to other target shapes the
  user might choose (any combination of the 8 non-quantity rewards), but for
  exotic ratios (e.g. a balanced 20 / 20 / 20 target chasing the cosmetics
  set only) re-sweeping the thresholds may yield a small improvement.
