# One-off: count paste consumed by the best policy over many trials.
# Each potion takes 3 paste units (some mix of mox/aga/lye depending on type).
source("mixology_sim.R")

PASTE_MAT <- as.matrix(potions[, c("mox_paste", "aga_paste", "lye_paste")])

simulate_with_paste <- function(policy) {
  resin  <- c(0, 0, 0)
  paste  <- c(0, 0, 0)
  brewed <- 0L
  orders <- sample_orders(3)
  repeat {
    deficit <- TARGET - resin
    if (all(deficit <= 0)) {
      return(list(brewed = brewed, paste = paste))
    }
    slots  <- policy(orders, deficit)
    n      <- length(slots)
    chosen <- orders[slots]
    resin  <- resin + colSums(RESIN_MAT[chosen, , drop = FALSE]) * BONUS[n]
    paste  <- paste + colSums(PASTE_MAT[chosen, , drop = FALSE])
    brewed <- brewed + n
    orders <- sample_orders(3)
  }
}

POL_NAME <- "two_plus_lye_bot"
N_TRIALS <- 1000L

set.seed(1)
pol <- default_policies[[POL_NAME]]
mox_p <- integer(N_TRIALS)
aga_p <- integer(N_TRIALS)
lye_p <- integer(N_TRIALS)
brewed_v <- integer(N_TRIALS)

cat(sprintf("[%s] running %d trials...\n", POL_NAME, N_TRIALS))
flush.console()
t0 <- Sys.time()
for (i in seq_len(N_TRIALS)) {
  res <- simulate_with_paste(pol)
  brewed_v[i] <- res$brewed
  mox_p[i] <- res$paste[1]
  aga_p[i] <- res$paste[2]
  lye_p[i] <- res$paste[3]
  gc(verbose = FALSE)
}
elapsed <- as.numeric(Sys.time() - t0, units = "secs")
cat(sprintf("done in %.1fs\n\n", elapsed))

cat(sprintf("=== Paste consumption for '%s' (n=%d) ===\n", POL_NAME, N_TRIALS))
cat(sprintf("Potions brewed: mean = %.0f  (p10 %.0f, p90 %.0f)\n",
            mean(brewed_v), quantile(brewed_v, 0.10), quantile(brewed_v, 0.90)))
cat(sprintf("Mox paste:      mean = %.0f  (p10 %.0f, p90 %.0f)\n",
            mean(mox_p), quantile(mox_p, 0.10), quantile(mox_p, 0.90)))
cat(sprintf("Aga paste:      mean = %.0f  (p10 %.0f, p90 %.0f)\n",
            mean(aga_p), quantile(aga_p, 0.10), quantile(aga_p, 0.90)))
cat(sprintf("Lye paste:      mean = %.0f  (p10 %.0f, p90 %.0f)\n",
            mean(lye_p), quantile(lye_p, 0.10), quantile(lye_p, 0.90)))
cat(sprintf("Total paste:    mean = %.0f\n",
            mean(mox_p + aga_p + lye_p)))
