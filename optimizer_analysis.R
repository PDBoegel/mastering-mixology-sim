# Run the per-turn optimizer (lookahead_greedy) on a seed range and log
# every decision. Designed to be called many times with different seed
# ranges so R's 4.5.2 / Windows instability never bites a long-running
# loop. Args: <seed_start> <n_trials> <out_csv>
source("mixology_sim.R")

args <- commandArgs(trailingOnly = TRUE)
seed_start <- if (length(args) >= 1) as.integer(args[[1]]) else 1L
n_trials   <- if (length(args) >= 2) as.integer(args[[2]]) else 25L
out_csv    <- if (length(args) >= 3) args[[3]] else "optimizer_decisions.csv"

hand_sig <- function(o) {
  m <- sum(RESIN_MAT[o, 1L] > 0)
  a <- sum(RESIN_MAT[o, 2L] > 0)
  l <- sum(RESIN_MAT[o, 3L] > 0)
  sprintf("%d/%d/%d", m, a, l)
}

policy <- default_policies[["optimizer"]]
all_logs <- vector("list", n_trials)
trial_potions <- integer(n_trials)

cat(sprintf("Optimizer logging: seeds %d..%d (%d trials) -> %s\n",
            seed_start, seed_start + n_trials - 1L, n_trials, out_csv))
flush.console()
t0 <- Sys.time()

for (k in seq_len(n_trials)) {
  trial <- seed_start + k - 1L
  set.seed(trial)
  resin <- c(0, 0, 0)
  brewed <- 0L
  orders <- sample_orders(3)
  turns <- 0L
  rows <- vector("list", 8000L)

  repeat {
    deficit <- TARGET - resin
    if (all(deficit <= 0)) break
    slots <- policy(orders, deficit)
    n <- length(slots)
    turns <- turns + 1L
    rows[[turns]] <- list(
      trial = trial, turn = turns, hand = hand_sig(orders),
      n = n, slots = paste(sort(slots), collapse = ""),
      d_mox = deficit[1], d_aga = deficit[2], d_lye = deficit[3]
    )
    gained <- colSums(RESIN_MAT[orders[slots], , drop = FALSE]) * BONUS[n]
    resin <- resin + gained
    brewed <- brewed + n
    orders <- sample_orders(3)
  }

  rows <- rows[seq_len(turns)]
  all_logs[[k]] <- do.call(rbind, lapply(rows, as.data.frame))
  trial_potions[k] <- brewed
  gc(verbose = FALSE)
  cat(sprintf("  seed %d: %d potions in %d turns\n", trial, brewed, turns))
  flush.console()
}

elapsed <- as.numeric(Sys.time() - t0, units = "secs")
cat(sprintf("done in %.1fs (mean = %.0f)\n", elapsed, mean(trial_potions)))

log_df <- do.call(rbind, all_logs)
utils::write.csv(log_df, out_csv, row.names = FALSE)
cat(sprintf("wrote %s (%d rows)\n", out_csv, nrow(log_df)))
