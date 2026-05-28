# Mastering Mixology strategy simulator
# ----------------------------------------------------------------------------
# Monte-Carlo evaluator for order-submission policies in the Mastering
# Mixology minigame (OSRS). See STRATEGY.md in this directory for the full
# write-up and the recommended algorithm for plugin implementation.
#
# Layout of this file:
#   1. Game data       (potions tibble + cached matrices + TARGET, BONUS)
#   2. Helpers         (deficit_scores)
#   3. TRIGGERS        (predicates on (orders, deficit) gating "submit all 3")
#   4. FALLBACKS       (action when no trigger fires; always returns >= 1 slot)
#   5. make_policy     (closure factory: triggers + combine mode + fallback)
#   6. simulate_one    (one trial: random orders, apply policy, count potions)
#   7. Runner          (run_policy / run_all / summarize / plot)
#   8. default_policies (registry, grouped by strategy class)
#   9. make_meta_policy + meta variants (adaptive state-machine policies)
#  10. CLI entry       (modes: all / single / chunk / summarize)
#
# Run modes (Rscript mixology_sim.R <mode> ...):
#   single    <policy> <n_trials> <out_rds>          -- run one policy, save
#   chunk     <policy> <n_trials> <out_rds> <seed>   -- one seeded chunk
#   summarize <in_dir> <png_path> <csv_path>         -- aggregate RDS files
#   all       [n_trials]                             -- in-process leaderboard
#
# TARGET is overridable via the MIX_TARGET env var ("mox,aga,lye"). Default
# is the user's original remaining-rewards target.

suppressPackageStartupMessages({
  library(tibble)
  library(dplyr)
  library(purrr)
  library(ggplot2)
})

# ---- Constants -------------------------------------------------------------

potions <- tibble::tibble(
  name      = c("MMM","AAA","LLL","MMA","MML","AAM","ALA","MLL","ALL","MAL"),
  mox_paste = c(  3,   0,   0,   2,   2,   1,   0,   1,   0,   1),
  aga_paste = c(  0,   3,   0,   1,   0,   2,   2,   0,   1,   1),
  lye_paste = c(  0,   0,   3,   0,   1,   0,   1,   2,   2,   1),
  # Resin rule: XXX -> 20 X; XXY -> 20 X + 10 Y; XYZ (MAL only) -> 20/20/20
  mox_resin = c( 20,   0,   0,  20,  20,  10,   0,  10,   0,  20),
  aga_resin = c(  0,  20,   0,  10,   0,  20,  20,   0,  10,  20),
  lye_resin = c(  0,   0,  20,   0,  10,   0,  10,  20,  20,  20),
  weight    = c(  5,   5,   5,   4,   4,   4,   4,   4,   4,   3)
)

# Hot-path arrays (avoid tibble slicing in inner loop)
RESIN_MAT <- as.matrix(potions[, c("mox_resin","aga_resin","lye_resin")])
WEIGHTS   <- potions$weight
N_POTIONS <- nrow(potions)
MAL_ID    <- which(potions$name == "MAL")
MMM_ID    <- which(potions$name == "MMM")
SINGLES   <- which(potions$name %in% c("MMM","AAA","LLL"))

# TARGET may be overridden via the MIX_TARGET env var (comma-separated
# mox,aga,lye). Default = remaining cost for the full reward set.
TARGET <- local({
  v <- Sys.getenv("MIX_TARGET", "")
  if (nchar(v) > 0) {
    parts <- as.integer(strsplit(v, ",")[[1]])
    stopifnot(length(parts) == 3L)
    setNames(parts, c("mox", "aga", "lye"))
  } else {
    c(mox = 45138, aga = 39220, lye = 52684)
  }
})
BONUS  <- c(1.0, 1.2, 1.4)  # indexed by number of potions submitted

# ---- Vectorized slot scoring -----------------------------------------------
# Returns numeric(length(o)): each slot's deficit-reduction score
# = sum_color(resin_color * max(deficit_color, 0)).
deficit_scores <- function(o, d) {
  drop(RESIN_MAT[o, , drop = FALSE] %*% pmax(d, 0))
}

# ---- Trigger library --------------------------------------------------------
# Each: function(order_ids, deficit) -> logical(1).
# When the policy's combined triggers fire, the player submits all 3 potions.

TRIGGERS <- list(
  all_lye        = function(o, d) all(RESIN_MAT[o, 3L] > 0),
  two_plus_lye   = function(o, d) sum(RESIN_MAT[o, 3L] > 0) >= 2,
  any_lye        = function(o, d) any(RESIN_MAT[o, 3L] > 0),
  has_mal        = function(o, d) any(o == MAL_ID),
  # multi_resin: every order is a 2+-resin potion (no MMM/AAA/LLL).
  # Equivalent formulation `no_single = !any(o %in% SINGLES)` was removed;
  # both expressions describe the same condition.
  multi_resin    = function(o, d) all(rowSums(RESIN_MAT[o, , drop = FALSE] > 0) >= 2),
  no_mmm         = function(o, d) !any(o == MMM_ID),
  not_all_single = function(o, d) !all(o %in% SINGLES),
  helps_deficit  = function(o, d) all(deficit_scores(o, d) > 0),
  # Fires when current lye resin is strictly greater than both current mox
  # and current aga (no summation). resin = TARGET - d.
  lye_ahead      = function(o, d) {
    resin <- TARGET - d
    resin[3] > resin[1] && resin[3] > resin[2]
  },
  # Fires when >= 2 of the 3 orders give BOTH of the two most-needed
  # colours. Identifies the top-2 deficit colours dynamically each turn,
  # then counts slots whose potion gives both of them.
  two_dual_bottleneck = function(o, d) {
    d_pos <- pmax(d, 0)
    if (sum(d_pos > 0) < 2L) return(FALSE)
    bn <- order(d_pos, decreasing = TRUE)[1:2]
    cnt <- sum(RESIN_MAT[o, bn[1]] > 0 & RESIN_MAT[o, bn[2]] > 0)
    cnt >= 2L
  },
  # Lenient variant of two_dual_bottleneck: fires when >= 2 of the 3
  # orders give EITHER of the top-2 deficit colours (union, not the
  # intersection). More permissive -- captures hands where 2 different
  # slots cover the two top deficits separately.
  two_either_top2 = function(o, d) {
    d_pos <- pmax(d, 0)
    if (sum(d_pos > 0) < 2L) return(FALSE)
    bn <- order(d_pos, decreasing = TRUE)[1:2]
    cnt <- sum(RESIN_MAT[o, bn[1]] > 0 | RESIN_MAT[o, bn[2]] > 0)
    cnt >= 2L
  },
  # Hybrid: strict (intersection) when top-2 deficits are clearly apart;
  # lenient (union) when they are effectively tied. Three variants below
  # differ only in the "tied" threshold. Use the small one (01%) to barely
  # smooth ties; the larger ones to be more aggressive.
  two_dual_tied_01 = function(o, d) {
    d_pos <- pmax(d, 0)
    if (sum(d_pos > 0) < 2L) return(FALSE)
    bn <- order(d_pos, decreasing = TRUE)[1:2]
    if (d_pos[bn[1]] <= 0) return(FALSE)
    g12 <- (d_pos[bn[1]] - d_pos[bn[2]]) / d_pos[bn[1]]
    cnt <- if (g12 < 0.01) {
      sum(RESIN_MAT[o, bn[1]] > 0 | RESIN_MAT[o, bn[2]] > 0)
    } else {
      sum(RESIN_MAT[o, bn[1]] > 0 & RESIN_MAT[o, bn[2]] > 0)
    }
    cnt >= 2L
  },
  two_dual_tied_05 = function(o, d) {
    d_pos <- pmax(d, 0)
    if (sum(d_pos > 0) < 2L) return(FALSE)
    bn <- order(d_pos, decreasing = TRUE)[1:2]
    if (d_pos[bn[1]] <= 0) return(FALSE)
    g12 <- (d_pos[bn[1]] - d_pos[bn[2]]) / d_pos[bn[1]]
    cnt <- if (g12 < 0.05) {
      sum(RESIN_MAT[o, bn[1]] > 0 | RESIN_MAT[o, bn[2]] > 0)
    } else {
      sum(RESIN_MAT[o, bn[1]] > 0 & RESIN_MAT[o, bn[2]] > 0)
    }
    cnt >= 2L
  },
  two_dual_tied_10 = function(o, d) {
    d_pos <- pmax(d, 0)
    if (sum(d_pos > 0) < 2L) return(FALSE)
    bn <- order(d_pos, decreasing = TRUE)[1:2]
    if (d_pos[bn[1]] <= 0) return(FALSE)
    g12 <- (d_pos[bn[1]] - d_pos[bn[2]]) / d_pos[bn[1]]
    cnt <- if (g12 < 0.10) {
      sum(RESIN_MAT[o, bn[1]] > 0 | RESIN_MAT[o, bn[2]] > 0)
    } else {
      sum(RESIN_MAT[o, bn[1]] > 0 & RESIN_MAT[o, bn[2]] > 0)
    }
    cnt >= 2L
  },
  # Same as two_plus_lye, but gated on lye still being needed -- so it
  # won't keep batching for lye once lye has hit target.
  lye_needed_two_plus = function(o, d) {
    if (d[3] <= 0) return(FALSE)
    sum(RESIN_MAT[o, 3L] > 0) >= 2L
  },
  # Generic version of lye_needed_two_plus: identify the colour with the
  # largest remaining deficit each turn and fire on >= 2 of the 3 orders
  # giving that colour. Adapts to whichever colour is currently binding.
  two_plus_bottleneck = function(o, d) {
    d_pos <- pmax(d, 0)
    if (all(d_pos == 0)) return(FALSE)
    col <- which.max(d_pos)
    sum(RESIN_MAT[o, col] > 0) >= 2L
  }
)

# ---- Fallback library -------------------------------------------------------
# Each: function(order_ids, deficit) -> integer slot indices in {1,2,3}.
# Always returns length >= 1 so the simulation makes progress.

FALLBACKS <- list(
  best_deficit_one = function(o, d) {
    which.max(deficit_scores(o, d))
  },
  best_deficit_two = function(o, d) {
    order(deficit_scores(o, d), decreasing = TRUE)[1:2]
  },
  greedy_all = function(o, d) c(1L, 2L, 3L),
  lye_giving_only = function(o, d) {
    idx <- which(RESIN_MAT[o, 3L] > 0)
    if (length(idx) == 0L) return(which.max(deficit_scores(o, d)))
    as.integer(idx)
  },
  non_overflow = function(o, d) {
    m <- RESIN_MAT[o, , drop = FALSE]
    sat <- d <= 0
    # slot kept iff no resin it produces is already satisfied
    keep <- !(m[, 1L] > 0 & sat[1L]) &
            !(m[, 2L] > 0 & sat[2L]) &
            !(m[, 3L] > 0 & sat[3L])
    idx <- which(keep)
    if (length(idx) == 0L) return(which.max(deficit_scores(o, d)))
    as.integer(idx)
  },
  helpful_only = function(o, d) {
    s <- deficit_scores(o, d)
    idx <- which(s > 0)
    if (length(idx) == 0L) return(1L)
    as.integer(idx)
  },
  # Pick the resin colour with the largest remaining deficit, then submit
  # every slot whose potion gives that colour. If none do, fall back to the
  # single best-deficit slot.
  bottleneck_color = function(o, d) {
    d_pos <- pmax(d, 0)
    if (all(d_pos == 0)) return(1L)
    col <- which.max(d_pos)
    idx <- which(RESIN_MAT[o, col] > 0)
    if (length(idx) == 0L) return(which.max(deficit_scores(o, d)))
    as.integer(idx)
  },
  # Per-turn optimizer: evaluates every non-empty subset of the 3 slots and
  # picks the one minimizing (potions in subset) + (max remaining deficit
  # after the action) / 14. The /14 term is approximately greedy's per-
  # potion fill rate per colour (E[resin/slot] = 400/42 = 9.52 under the
  # XXX=20 / XXY=20+10 / XYZ=20/20/20 yield rules, x 1.4 bonus = 13.33);
  # 14 was picked as a clean round number in the same ballpark.
  lookahead_greedy = function(o, d) {
    best_score <- Inf
    best_slots <- c(1L, 2L, 3L)
    for (mask in 1L:7L) {
      slots <- which(c(bitwAnd(mask, 1L), bitwAnd(mask, 2L), bitwAnd(mask, 4L)) > 0L)
      n <- length(slots)
      gained <- colSums(RESIN_MAT[o[slots], , drop = FALSE]) * BONUS[n]
      h <- max(pmax(d - gained, 0)) / 14
      score <- n + h
      if (score < best_score) {
        best_score <- score
        best_slots <- as.integer(slots)
      }
    }
    best_slots
  }
)

# ---- Policy constructor -----------------------------------------------------
# A policy is a closure (o, d) -> integer slot indices.
# Hot-loop friendly: no anonymous-function allocations per call.

make_policy <- function(triggers = character(),
                        combine  = c("any", "all"),
                        fallback = "best_deficit_one") {
  combine <- match.arg(combine)
  stopifnot(all(triggers %in% names(TRIGGERS)))
  stopifnot(fallback %in% names(FALLBACKS))
  trig_fns <- unname(TRIGGERS[triggers])
  fb_fn    <- FALLBACKS[[fallback]]
  n_trig   <- length(trig_fns)
  any_mode <- combine == "any"
  ALL3     <- c(1L, 2L, 3L)

  if (n_trig == 0L) {
    return(function(o, d) fb_fn(o, d))
  }

  # Specialize for common arities to avoid for-loop overhead
  if (n_trig == 1L) {
    f1 <- trig_fns[[1L]]
    return(function(o, d) if (f1(o, d)) ALL3 else fb_fn(o, d))
  }

  if (any_mode) {
    function(o, d) {
      for (k in seq_len(n_trig)) if (trig_fns[[k]](o, d)) return(ALL3)
      fb_fn(o, d)
    }
  } else {
    function(o, d) {
      for (k in seq_len(n_trig)) if (!trig_fns[[k]](o, d)) return(fb_fn(o, d))
      ALL3
    }
  }
}

# ---- Simulator core ---------------------------------------------------------

sample_orders <- function(n) {
  sample.int(N_POTIONS, n, replace = TRUE, prob = WEIGHTS)
}

simulate_one <- function(policy) {
  resin  <- c(0, 0, 0)
  brewed <- 0L
  orders <- sample_orders(3)
  repeat {
    deficit <- TARGET - resin
    if (all(deficit <= 0)) return(brewed)
    slots  <- policy(orders, deficit)
    n      <- length(slots)
    gained <- colSums(RESIN_MAT[orders[slots], , drop = FALSE]) * BONUS[n]
    resin  <- resin + gained
    brewed <- brewed + n
    # Every conveyor click refreshes all 3 orders, regardless of how many
    # potions were submitted.
    orders <- sample_orders(3)
  }
}

# ---- Runner -----------------------------------------------------------------

# GC every GC_EVERY trials. Empirically R 4.5.2 / Windows segfaults during
# long inner loops without periodic GC; once-per-trial is safe, larger gaps
# trade safety for speed.
GC_EVERY <- 1L

run_policy <- function(policy, n_trials, label) {
  pots <- integer(n_trials)
  for (i in seq_len(n_trials)) {
    pots[i] <- simulate_one(policy)
    if (i %% GC_EVERY == 0L) gc(verbose = FALSE)
  }
  tibble::tibble(policy = label, trial = seq_len(n_trials), potions = pots)
}

run_all <- function(policies, n_trials = 10000L, seed = 1L) {
  set.seed(seed)
  out <- vector("list", length(policies))
  names(out) <- names(policies)
  for (nm in names(policies)) {
    t0 <- Sys.time()
    out[[nm]] <- run_policy(policies[[nm]], n_trials, nm)
    elapsed <- as.numeric(Sys.time() - t0, units = "secs")
    cat(sprintf("  %-18s  mean=%7.0f  (%.1fs)\n",
                nm, mean(out[[nm]]$potions), elapsed))
    flush.console()
  }
  dplyr::bind_rows(out)
}

summarize_results <- function(res) {
  res |>
    dplyr::group_by(policy) |>
    dplyr::summarise(
      mean   = mean(potions),
      median = stats::median(potions),
      p10    = stats::quantile(potions, 0.10),
      p90    = stats::quantile(potions, 0.90),
      .groups = "drop"
    ) |>
    dplyr::arrange(mean)
}

plot_results <- function(res) {
  means <- res |>
    dplyr::group_by(policy) |>
    dplyr::summarise(mean = mean(potions), .groups = "drop")
  ggplot2::ggplot(res, ggplot2::aes(x = potions)) +
    ggplot2::geom_histogram(bins = 40, fill = "steelblue", alpha = 0.85) +
    ggplot2::geom_vline(data = means, ggplot2::aes(xintercept = mean),
                        linetype = "dashed", color = "firebrick") +
    ggplot2::facet_wrap(~ policy, scales = "free") +
    ggplot2::labs(
      title = "Mastering Mixology — potions brewed to finish all rewards",
      subtitle = sprintf("Targets: %.0f mox / %.0f aga / %.0f lye  |  %.0f trials per policy",
                         TARGET["mox"], TARGET["aga"], TARGET["lye"],
                         nrow(res) / dplyr::n_distinct(res$policy)),
      x = "Potions brewed", y = "Trials"
    ) +
    ggplot2::theme_minimal()
}

# ---- Policy registry --------------------------------------------------------
# Naming conventions:
#   <trigger>           -- single-trigger policy; descriptive trigger name
#   <trigger>_bot       -- "_bot" suffix = bottleneck_color fallback (submit
#                          slots matching the largest-deficit colour). Without
#                          this suffix the fallback is best_deficit_one.
#   <X>_or_<Y>          -- OR of two triggers
#   <X>_and_<Y>         -- AND of two triggers
#   meta_d<N>_b<M>_h<H> -- adaptive meta-policy with thresholds (see Sec. 9)
#
# Grouped by strategy class. See STRATEGY.md Sec. 4-5 for full descriptions.

default_policies <- list(

  # ---- Baselines & exploratory (best_deficit_one fallback) ----
  greedy          = make_policy(fallback = "greedy_all"),
  all_lye         = make_policy("all_lye",        fallback = "best_deficit_one"),
  two_plus_lye    = make_policy("two_plus_lye",   fallback = "best_deficit_one"),
  has_mal         = make_policy("has_mal",        fallback = "best_deficit_one"),
  multi_resin     = make_policy("multi_resin",    fallback = "best_deficit_one"),
  skip_mmm        = make_policy("no_mmm",         fallback = "helpful_only"),
  # Was: make_policy("no_single", fallback = "helpful_only"). The "no_single"
  # trigger duplicated multi_resin in logic; multi_resin (with the more
  # selective best_deficit_one fallback) dominates in every benchmark we
  # ran, so the no_single policy was removed entirely.
  skip_all_single = make_policy("not_all_single", fallback = "best_deficit_one"),
  skip_no_lye     = make_policy("any_lye",        fallback = "best_deficit_one"),
  lye_ahead       = make_policy("lye_ahead",      fallback = "best_deficit_one"),

  # ---- Two-trigger combinations ----
  mal_or_alllye   = make_policy(c("has_mal","all_lye"),      "any", "best_deficit_one"),
  mal_or_multi    = make_policy(c("has_mal","multi_resin"),  "any", "best_deficit_one"),
  mal_and_multi   = make_policy(c("has_mal","multi_resin"),  "all", "best_deficit_one"),
  lye_or_mal      = make_policy(c("has_mal","two_plus_lye"), "any", "lye_giving_only"),

  # ---- Bottleneck-colour-fallback variants (_bot suffix) ----
  # Same triggers as above but the fallback submits slots matching whichever
  # colour currently has the largest deficit.
  all_lye_bot       = make_policy("all_lye",             fallback = "bottleneck_color"),
  two_plus_lye_bot  = make_policy("two_plus_lye",        fallback = "bottleneck_color"),
  any_lye_bot       = make_policy("any_lye",             fallback = "bottleneck_color"),
  two_dual_bot      = make_policy("two_dual_bottleneck", fallback = "bottleneck_color"),

  # ---- Bottleneck-aware (dynamically tracks top-deficit colour) ----
  bottleneck_only = make_policy(fallback = "bottleneck_color"),
  two_plus_bn     = make_policy("two_plus_bottleneck", fallback = "bottleneck_color"),
  deficit_only    = make_policy("helps_deficit",       "any", "non_overflow"),

  # ---- Hybrid (composition of lye-counting + dual-bottleneck) ----
  hybrid_lye_dual = make_policy(c("lye_needed_two_plus", "two_dual_bottleneck"),
                                "any", "bottleneck_color"),

  # ---- Lenient dual: union-of-top-2 instead of intersection ----
  # Static analogue of the user-proposed dual rule: >= 2 of 3 slots give
  # EITHER top-1 or top-2 deficit colour. Triggers far more often than
  # two_dual_bot.
  two_either_top2_bot = make_policy("two_either_top2", fallback = "bottleneck_color"),
  # ---- Tied-only lenient: strict normally, lenient when deficits ~tied
  two_dual_tied_01_bot = make_policy("two_dual_tied_01", fallback = "bottleneck_color"),
  two_dual_tied_05_bot = make_policy("two_dual_tied_05", fallback = "bottleneck_color"),
  two_dual_tied_10_bot = make_policy("two_dual_tied_10", fallback = "bottleneck_color"),

  # ---- 1-step lookahead optimizer (heuristic; see STRATEGY.md Sec. 6) ----
  optimizer       = make_policy(fallback = "lookahead_greedy")
)

# ---- Meta-policy: switches sub-policy by deficit shape ---------------------
# State machine over (single_bn, dual_bn, balanced):
#   * "balanced" entered when all-3 deficits are within t_balanced_in of the
#     largest deficit (relative gap (max - min)/max < t_balanced_in).
#   * "dual_bn"  entered when top-2 are within t_dual_in (and not balanced).
#   * "single_bn" otherwise.
# Hysteresis: only LEAVE a state when the gap widens past t_*_out (so we
# don't thrash). State resets to single_bn whenever a new trial begins
# (detected by deficit == TARGET at trial 0).
make_meta_policy <- function(t_dual_in     = 0.05,
                             t_dual_out    = 0.10,
                             t_balanced_in = 0.05,
                             t_balanced_out= 0.10,
                             pol_single    = "two_plus_bn",
                             pol_dual      = "two_dual_bot",
                             pol_balanced  = "multi_resin") {
  state <- "single_bn"
  sub_single   <- default_policies[[pol_single]]
  sub_dual     <- default_policies[[pol_dual]]
  sub_balanced <- default_policies[[pol_balanced]]
  target_int <- as.integer(unname(TARGET))

  function(o, d) {
    # Detect start of a new trial -- TARGET == d when resin is still zero.
    if (isTRUE(all(as.integer(d) == target_int))) state <<- "single_bn"

    d_pos <- pmax(d, 0)
    sorted <- sort(d_pos, decreasing = TRUE)
    max_d <- sorted[1L]; mid_d <- sorted[2L]; min_d <- sorted[3L]
    gap_12 <- if (max_d <= 0) Inf else (max_d - mid_d) / max_d
    gap_13 <- if (max_d <= 0) Inf else (max_d - min_d) / max_d

    if (state == "single_bn") {
      if (gap_13 < t_balanced_in) state <<- "balanced"
      else if (gap_12 < t_dual_in) state <<- "dual_bn"
    } else if (state == "dual_bn") {
      if (gap_13 < t_balanced_in) state <<- "balanced"
      else if (gap_12 > t_dual_out) state <<- "single_bn"
    } else {
      if (gap_13 > t_balanced_out) {
        state <<- if (gap_12 < t_dual_in) "dual_bn" else "single_bn"
      }
    }

    if      (state == "balanced") sub_balanced(o, d)
    else if (state == "dual_bn")  sub_dual(o, d)
    else                          sub_single(o, d)
  }
}

# Threshold-sweep meta-policy grid. Naming: meta_dN_bM_hH where
#   N = t_dual_in  * 100   (enter dual_bn when top-2 gap < N%)
#   M = t_balanced_in * 100 (enter balanced when all-3 gap < M%)
#   H = hysteresis * 100   (must widen H% past the in-threshold to leave)
#
# The recommended values for plugin use are t_dual_in=0.20, t_balanced_in=
# 0.10, hysteresis=0.05 (see STRATEGY.md Sec. 7). The other variants are
# kept for reproducibility of the sweep.
default_policies[["meta_recommended"]]  <- make_meta_policy(0.20, 0.25, 0.10, 0.15)

default_policies[["meta_d05_b02_h05"]]  <- make_meta_policy(0.05, 0.10, 0.02, 0.07)
default_policies[["meta_d05_b05_h05"]]  <- make_meta_policy(0.05, 0.10, 0.05, 0.10)
default_policies[["meta_d10_b02_h05"]]  <- make_meta_policy(0.10, 0.15, 0.02, 0.07)
default_policies[["meta_d10_b05_h05"]]  <- make_meta_policy(0.10, 0.15, 0.05, 0.10)
default_policies[["meta_d10_b05_h10"]]  <- make_meta_policy(0.10, 0.20, 0.05, 0.15)
default_policies[["meta_d15_b05_h05"]]  <- make_meta_policy(0.15, 0.20, 0.05, 0.10)
default_policies[["meta_d20_b05_h05"]]  <- make_meta_policy(0.20, 0.25, 0.05, 0.10)
# meta_d20_b10_h05 omitted -- same parameters as meta_recommended above.
default_policies[["meta_d30_b10_h05"]]  <- make_meta_policy(0.30, 0.35, 0.10, 0.15)
default_policies[["meta_d20_b10_h02"]]  <- make_meta_policy(0.20, 0.22, 0.10, 0.12)
default_policies[["meta_d20_b10_h10"]]  <- make_meta_policy(0.20, 0.30, 0.10, 0.20)
default_policies[["meta_d25_b10_h05"]]  <- make_meta_policy(0.25, 0.30, 0.10, 0.15)
default_policies[["meta_d40_b10_h05"]]  <- make_meta_policy(0.40, 0.45, 0.10, 0.15)
default_policies[["meta_d20_b20_h05"]]  <- make_meta_policy(0.20, 0.25, 0.20, 0.25)
default_policies[["meta_d50_b20_h05"]]  <- make_meta_policy(0.50, 0.55, 0.20, 0.25)

# Lenient-dual meta variants -- same shape as the recommended grid but
# the dual_bn sub-policy uses the union "either top-1 or top-2" rule
# instead of the strict intersection. Tests the user's hunch that a more
# permissive dual rule yields fewer total potions.
default_policies[["meta_lenient_recommended"]] <- make_meta_policy(
        0.20, 0.25, 0.10, 0.15, pol_dual = "two_either_top2_bot")
# meta_lenient_d20_b10_h05 omitted -- same parameters as
# meta_lenient_recommended above.
default_policies[["meta_lenient_d30_b10_h05"]] <- make_meta_policy(
        0.30, 0.35, 0.10, 0.15, pol_dual = "two_either_top2_bot")
default_policies[["meta_lenient_d20_b20_h05"]] <- make_meta_policy(
        0.20, 0.25, 0.20, 0.25, pol_dual = "two_either_top2_bot")
default_policies[["meta_lenient_d50_b20_h05"]] <- make_meta_policy(
        0.50, 0.55, 0.20, 0.25, pol_dual = "two_either_top2_bot")

# Tied-only-lenient meta variants -- recommended thresholds but the
# dual_bn sub-policy uses the hybrid trigger that only goes lenient when
# top-2 deficits are essentially tied (gap < 1/5/10%).
default_policies[["meta_tied_01"]] <- make_meta_policy(
        0.20, 0.25, 0.10, 0.15, pol_dual = "two_dual_tied_01_bot")
default_policies[["meta_tied_05"]] <- make_meta_policy(
        0.20, 0.25, 0.10, 0.15, pol_dual = "two_dual_tied_05_bot")
default_policies[["meta_tied_10"]] <- make_meta_policy(
        0.20, 0.25, 0.10, 0.15, pol_dual = "two_dual_tied_10_bot")

# ---- Self-test --------------------------------------------------------------

self_test <- function() {
  set.seed(42)
  g <- make_policy(fallback = "greedy_all")
  n <- simulate_one(g)
  stopifnot(n > 0, n < 50000)

  d <- c(100, 0, 0)
  s <- FALLBACKS$best_deficit_one(
    c(MMM_ID,
      which(potions$name == "LLL"),
      which(potions$name == "AAA")),
    d
  )
  stopifnot(s == 1L)  # MMM helps mox-only deficit

  s2 <- FALLBACKS$lye_giving_only(c(MMM_ID, MAL_ID, MAL_ID), c(0, 0, 100))
  stopifnot(setequal(s2, c(2L, 3L)))

  invisible(TRUE)
}

# ---- Modes ------------------------------------------------------------------
# R 4.5.2 / Windows is unstable under long-running tight loops, so the
# orchestrator runs each policy in its own Rscript process. The two modes
# below cover that:
#   single  — run one policy, write results to an RDS file, exit.
#   summarize — read all per-policy RDS files in a dir, write summary+plot.
# A traditional single-process "all" mode is kept for quick small runs.

run_single <- function(policy_name, n_trials, out_path, seed = 1L) {
  self_test()
  stopifnot(policy_name %in% names(default_policies))
  dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
  set.seed(seed + utf8ToInt(substr(policy_name, 1, 1)))
  cat(sprintf("[%s] running %d trials...\n", policy_name, n_trials))
  flush.console()
  t0 <- Sys.time()

  # Inline simulate loop. Empirically more stable on R 4.5.2 than going
  # through the run_policy() wrapper for certain policies; passing the
  # closure as a function argument seemed to interact badly with GC.
  pots <- integer(n_trials)
  for (i in seq_len(n_trials)) {
    pots[i] <- simulate_one(default_policies[[policy_name]])
    gc(verbose = FALSE)
  }
  res <- tibble::tibble(policy = policy_name, trial = seq_len(n_trials),
                        potions = pots)

  elapsed <- as.numeric(Sys.time() - t0, units = "secs")
  cat(sprintf("[%s] done: mean=%.0f, %.1fs\n",
              policy_name, mean(res$potions), elapsed))
  saveRDS(res, out_path)
  invisible(res)
}

run_summarize <- function(in_dir, png_path, csv_path) {
  files <- list.files(in_dir, pattern = "^policy_.*\\.rds$", full.names = TRUE)
  stopifnot(length(files) > 0)
  parts <- lapply(files, readRDS)
  res <- dplyr::bind_rows(parts)
  # Some policies may be split across multiple chunk files; collapse trial
  # indices so the histogram facet sees a single coherent sample per policy.
  res <- res |>
    dplyr::group_by(policy) |>
    dplyr::mutate(trial = dplyr::row_number()) |>
    dplyr::ungroup()
  summary <- summarize_results(res)
  cat("\n=== Summary (sorted by mean potions brewed) ===\n")
  print(summary, n = Inf)
  utils::write.csv(summary, csv_path, row.names = FALSE)
  ggplot2::ggsave(png_path, plot_results(res),
                  width = 14, height = 9, dpi = 100)
  cat(sprintf("\nWrote: %s\n       %s\n", csv_path, png_path))
  invisible(list(results = res, summary = summary))
}

# Run one chunk of N trials for a single policy. Used to assemble samples
# across multiple Rscript processes when a single 1000-trial run is
# unstable.
run_chunk <- function(policy_name, n_trials, out_path, seed) {
  self_test()
  stopifnot(policy_name %in% names(default_policies))
  dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
  set.seed(seed)
  cat(sprintf("[%s chunk seed=%d] running %d trials...\n",
              policy_name, seed, n_trials))
  flush.console()
  t0 <- Sys.time()
  pots <- integer(n_trials)
  for (i in seq_len(n_trials)) {
    pots[i] <- simulate_one(default_policies[[policy_name]])
    gc(verbose = FALSE)
  }
  res <- tibble::tibble(policy = policy_name, trial = seq_len(n_trials),
                        potions = pots)
  elapsed <- as.numeric(Sys.time() - t0, units = "secs")
  cat(sprintf("[%s chunk seed=%d] done: mean=%.0f, %.1fs\n",
              policy_name, seed, mean(pots), elapsed))
  saveRDS(res, out_path)
  invisible(res)
}

main_all <- function(n_trials = 1000L) {
  self_test()
  cat(sprintf("Mastering Mixology simulator — %d trials per policy\n\n", n_trials))
  res <- run_all(default_policies, n_trials = n_trials)
  cat("\n=== Summary (sorted by mean potions brewed) ===\n")
  summary <- summarize_results(res)
  print(summary, n = Inf)
  out_dir <- getwd()
  utils::write.csv(summary, file.path(out_dir, "mixology_summary.csv"),
                   row.names = FALSE)
  ggplot2::ggsave(file.path(out_dir, "mixology_results.png"),
                  plot_results(res), width = 14, height = 9, dpi = 100)
  invisible(list(results = res, summary = summary))
}

# CLI entry
if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  mode <- if (length(args) >= 1L) args[[1]] else "all"

  if (mode == "single") {
    # Rscript mixology_sim.R single <policy_name> <n_trials> <out_path>
    stopifnot(length(args) >= 4L)
    run_single(args[[2]], as.integer(args[[3]]), args[[4]])
  } else if (mode == "chunk") {
    # Rscript mixology_sim.R chunk <policy_name> <n_trials> <out_path> <seed>
    stopifnot(length(args) >= 5L)
    run_chunk(args[[2]], as.integer(args[[3]]), args[[4]],
              as.integer(args[[5]]))
  } else if (mode == "summarize") {
    # Rscript mixology_sim.R summarize <in_dir> <png_path> <csv_path>
    stopifnot(length(args) >= 4L)
    run_summarize(args[[2]], args[[3]], args[[4]])
  } else if (mode == "all") {
    # Rscript mixology_sim.R all [n_trials]
    n <- if (length(args) >= 2L) as.integer(args[[2]]) else 1000L
    main_all(n)
  } else {
    # First arg looks like a number — back-compat: treat as n_trials for "all"
    n <- suppressWarnings(as.integer(mode))
    if (!is.na(n)) main_all(n) else stop("Unknown mode: ", mode)
  }
}
