# Run two_plus_lye_bot on a seed range, log every decision, write CSV.
# Args: <policy> <seed_start> <n_trials> <out_csv>
source("mixology_sim.R")

args <- commandArgs(trailingOnly = TRUE)
policy_name <- if (length(args) >= 1) args[[1]] else "two_plus_lye_bot"
seed_start  <- if (length(args) >= 2) as.integer(args[[2]]) else 1L
n_trials    <- if (length(args) >= 3) as.integer(args[[3]]) else 25L
out_csv     <- if (length(args) >= 4) args[[4]] else "policy_decisions.csv"

hand_sig <- function(o) {
  m <- sum(RESIN_MAT[o, 1L] > 0)
  a <- sum(RESIN_MAT[o, 2L] > 0)
  l <- sum(RESIN_MAT[o, 3L] > 0)
  sprintf("%d/%d/%d", m, a, l)
}

policy <- default_policies[[policy_name]]
all_rows <- vector("list", n_trials)
potions_v <- integer(n_trials)

cat(sprintf("[%s] seeds %d..%d logging decisions -> %s\n",
            policy_name, seed_start, seed_start + n_trials - 1L, out_csv))
flush.console()
t0 <- Sys.time()

for (k in seq_len(n_trials)) {
  seed <- seed_start + k - 1L
  set.seed(seed)
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
      trial = seed, turn = turns, hand = hand_sig(orders),
      n = n, slots = paste(sort(slots), collapse = ""),
      d_mox = deficit[1], d_aga = deficit[2], d_lye = deficit[3]
    )
    gained <- colSums(RESIN_MAT[orders[slots], , drop = FALSE]) * BONUS[n]
    resin <- resin + gained
    brewed <- brewed + n
    orders <- sample_orders(3)
  }

  rows <- rows[seq_len(turns)]
  all_rows[[k]] <- do.call(rbind, lapply(rows, as.data.frame))
  potions_v[k] <- brewed
  gc(verbose = FALSE)
  cat(sprintf("  seed %d: %d potions in %d turns\n", seed, brewed, turns))
  flush.console()
}

elapsed <- as.numeric(Sys.time() - t0, units = "secs")
cat(sprintf("done in %.1fs (mean = %.0f)\n", elapsed, mean(potions_v)))

log_df <- do.call(rbind, all_rows)
utils::write.csv(log_df, out_csv, row.names = FALSE)
cat(sprintf("wrote %s (%d rows)\n", out_csv, nrow(log_df)))
