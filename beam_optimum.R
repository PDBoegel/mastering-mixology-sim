# Approximate minimum potions for a fixed order sequence via beam search.
#
# State at each turn: a matrix (m, a, l, g).  Expand all 7 actions, dedup
# by (m, a, l) keeping min g, prune by admissible UB, keep top-K by f =
# g + ceil(max(remaining)/28).  /28 is the max resin per potion in any
# colour under the doubled-yield rules (20 base x 1.4 three-batch bonus on
# the doubled colour). As K grows, the answer converges to the exact
# optimum. Verification: re-run with two beam widths and confirm match.
#
# CLI:  Rscript beam_optimum.R <seed_start> <n_trials> <beam_K> <out_csv>
source("mixology_sim.R")

args <- commandArgs(trailingOnly = TRUE)
seed_start <- if (length(args) >= 1) as.integer(args[[1]]) else 1L
n_trials   <- if (length(args) >= 2) as.integer(args[[2]]) else 1L
beam_K     <- if (length(args) >= 3) as.integer(args[[3]]) else 50000L
out_csv    <- if (length(args) >= 4) args[[4]] else "beam_optimum.csv"

TM <- as.integer(TARGET[1]); TA <- as.integer(TARGET[2]); TL <- as.integer(TARGET[3])
SUBSETS <- list(c(1L), c(2L), c(3L), c(1L,2L), c(1L,3L), c(2L,3L), c(1L,2L,3L))
SUBSET_SIZE <- vapply(SUBSETS, length, integer(1))
N_TURNS_MAX <- 8000L

precompute_gains <- function(orders_seq) {
  n <- nrow(orders_seq)
  arr <- array(0L, dim = c(n, 7L, 3L))
  for (s in seq_along(SUBSETS)) {
    slots <- SUBSETS[[s]]
    bonus <- BONUS[length(slots)]
    for (t in seq_len(n)) {
      arr[t, s, ] <- as.integer(colSums(RESIN_MAT[orders_seq[t, slots], , drop = FALSE]) * bonus)
    }
  }
  arr
}

upper_bound_from_policy <- function(orders_seq, policy_name = "two_plus_lye_bot") {
  pol <- default_policies[[policy_name]]
  resin <- c(0L, 0L, 0L)
  brewed <- 0L
  for (t in seq_len(nrow(orders_seq))) {
    if (resin[1] >= TM && resin[2] >= TA && resin[3] >= TL) break
    orders <- orders_seq[t, ]
    deficit <- TARGET - resin
    slots <- pol(orders, deficit)
    n <- length(slots)
    resin <- resin + as.integer(colSums(RESIN_MAT[orders[slots], , drop = FALSE]) * BONUS[n])
    brewed <- brewed + n
  }
  brewed
}

beam_search <- function(orders_seq, ub, K) {
  gain_table <- precompute_gains(orders_seq)
  n_turns <- nrow(orders_seq)

  # State columns: m, a, l, g
  states <- matrix(c(0L, 0L, 0L, 0L), ncol = 4L, byrow = TRUE)
  best <- ub

  KEY_A <- 60000L  # > TA
  KEY_L <- 60000L  # > TL  (state key = m * KEY_A * KEY_L + a * KEY_L + l)

  for (t in seq_len(n_turns)) {
    nrows <- nrow(states)
    if (nrows == 0L) break

    # Expand all 7 actions into a stacked matrix
    expanded <- matrix(0L, nrow = nrows * 7L, ncol = 4L)
    for (s in seq_len(7L)) {
      g_m <- gain_table[t, s, 1L]
      g_a <- gain_table[t, s, 2L]
      g_l <- gain_table[t, s, 3L]
      cost <- SUBSET_SIZE[s]
      base <- (s - 1L) * nrows + 1L
      expanded[base:(base + nrows - 1L), 1L] <- pmin(states[, 1L] + g_m, TM)
      expanded[base:(base + nrows - 1L), 2L] <- pmin(states[, 2L] + g_a, TA)
      expanded[base:(base + nrows - 1L), 3L] <- pmin(states[, 3L] + g_l, TL)
      expanded[base:(base + nrows - 1L), 4L] <- states[, 4L] + cost
    }

    # Goal states
    goal <- expanded[, 1L] >= TM & expanded[, 2L] >= TA & expanded[, 3L] >= TL
    if (any(goal)) {
      candidate <- min(expanded[goal, 4L])
      if (candidate < best) best <- candidate
    }

    # Filter non-goal
    expanded <- expanded[!goal, , drop = FALSE]
    if (nrow(expanded) == 0L) {
      states <- matrix(0L, nrow = 0L, ncol = 4L)
      next
    }

    # Prune by f = g + h
    rem <- pmax(TM - expanded[, 1L], TA - expanded[, 2L], TL - expanded[, 3L])
    h <- as.integer(ceiling(rem / 28))
    f <- expanded[, 4L] + h
    keep <- f < best
    expanded <- expanded[keep, , drop = FALSE]
    f <- f[keep]
    if (nrow(expanded) == 0L) {
      states <- matrix(0L, nrow = 0L, ncol = 4L)
      next
    }

    # Dedup by (m, a, l), keeping min g
    # Encode key as double (m * 6e4 * 6e4 + a * 6e4 + l fits in 2^53).
    key <- as.numeric(expanded[, 1L]) * (KEY_A * 1.0) * (KEY_L * 1.0) +
           as.numeric(expanded[, 2L]) * (KEY_L * 1.0) +
           as.numeric(expanded[, 3L])
    ord_g <- order(expanded[, 4L])
    expanded <- expanded[ord_g, , drop = FALSE]
    key <- key[ord_g]
    f <- f[ord_g]
    keep <- !duplicated(key)
    expanded <- expanded[keep, , drop = FALSE]
    f <- f[keep]

    # Keep top-K by f
    if (nrow(expanded) > K) {
      ord_f <- order(f)
      expanded <- expanded[ord_f[seq_len(K)], , drop = FALSE]
    }

    states <- expanded

    if (t %% 200L == 0L) {
      cat(sprintf("    turn %d  open=%d  best=%d\n", t, nrow(states), best))
      flush.console()
    }
  }

  best
}

results <- data.frame(seed = integer(0), beam_K = integer(0),
                      ub = integer(0), beam_opt = integer(0),
                      seconds = numeric(0))

for (k in seq_len(n_trials)) {
  seed <- seed_start + k - 1L
  set.seed(seed)
  orders_seq <- matrix(0L, nrow = N_TURNS_MAX, ncol = 3L)
  for (t in seq_len(N_TURNS_MAX)) {
    orders_seq[t, ] <- sample_orders(3L)
  }

  ub <- upper_bound_from_policy(orders_seq)
  cat(sprintf("seed %d: UB(two_plus_lye_bot) = %d. Beam K=%d ...\n",
              seed, ub, beam_K))
  flush.console()

  t0 <- Sys.time()
  bo <- beam_search(orders_seq, ub, beam_K)
  elapsed <- as.numeric(Sys.time() - t0, units = "secs")

  cat(sprintf("seed %d: BEAM(K=%d) = %d  (saved %d below UB)  %.1fs\n",
              seed, beam_K, bo, ub - bo, elapsed))
  flush.console()

  results <- rbind(results, data.frame(
    seed = seed, beam_K = beam_K, ub = ub, beam_opt = bo, seconds = elapsed
  ))
  gc(verbose = FALSE)
}

utils::write.csv(results, out_csv, row.names = FALSE)
cat(sprintf("\nwrote %s\n", out_csv))
print(results)
