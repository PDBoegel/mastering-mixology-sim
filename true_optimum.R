# Exact minimum potions for a fixed order sequence via forward DP.
#
# State at turn t = (mox, aga, lye) clamped at TARGET.  At each turn we
# expand every reachable state's 7 action successors, keeping only the best
# g (potions used) per resulting state.  Two-layer rolling memory.  Prune
# successors whose g + max(remaining)/14 >= current best (admissible).
#
# CLI:  Rscript true_optimum.R <seed_start> <n_trials> <out_csv>
source("mixology_sim.R")
suppressPackageStartupMessages({ library(fastmap) })

args <- commandArgs(trailingOnly = TRUE)
seed_start <- if (length(args) >= 1) as.integer(args[[1]]) else 1L
n_trials   <- if (length(args) >= 2) as.integer(args[[2]]) else 1L
out_csv    <- if (length(args) >= 3) args[[3]] else "true_optimum.csv"

TM <- TARGET[1]; TA <- TARGET[2]; TL <- TARGET[3]
SUBSETS <- list(c(1L), c(2L), c(3L), c(1L,2L), c(1L,3L), c(2L,3L), c(1L,2L,3L))
SUBSET_SIZE <- vapply(SUBSETS, length, integer(1))
N_TURNS_MAX <- 8000L

precompute_gains <- function(orders_seq) {
  n <- nrow(orders_seq)
  arr <- array(0L, dim = c(n, 7L, 3L))
  for (s in seq_along(SUBSETS)) {
    slots <- SUBSETS[[s]]
    sz <- length(slots)
    bonus <- BONUS[sz]
    for (t in seq_len(n)) {
      arr[t, s, ] <- as.integer(colSums(RESIN_MAT[orders_seq[t, slots], , drop = FALSE]) * bonus)
    }
  }
  arr
}

# Seed UB with a strong policy so we can prune aggressively.
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

# Heuristic: integer lower bound on remaining potions.
remaining_h <- function(m, a, l) {
  rem <- c(TM - m, TA - a, TL - l)
  rem[rem < 0] <- 0L
  as.integer(ceiling(max(rem) / 14))
}

dp_min <- function(orders_seq, ub) {
  cat("    precomputing gains...\n"); flush.console()
  gain_table <- precompute_gains(orders_seq)
  cat("    gains done, dim = ", paste(dim(gain_table), collapse = "x"), "\n"); flush.console()
  n_turns <- nrow(orders_seq)

  # layer: fastmap key = "m|a|l", value = best g to reach
  layer <- fastmap::fastmap()
  layer$set("0|0|0", 0L)

  best <- ub
  total_states <- 0L
  turn_taken <- 0L

  for (t in seq_len(n_turns)) {
    if (layer$size() == 0L) break
    next_layer <- fastmap::fastmap()

    keys <- layer$keys()
    for (key in keys) {
      g <- layer$get(key)
      mal <- as.integer(strsplit(key, "|", fixed = TRUE)[[1]])
      m <- mal[1]; a <- mal[2]; l <- mal[3]

      for (s in seq_len(7L)) {
        gain <- gain_table[t, s, ]
        nm <- min(m + gain[1L], TM)
        na <- min(a + gain[2L], TA)
        nl <- min(l + gain[3L], TL)
        ng <- g + SUBSET_SIZE[s]

        if (nm >= TM && na >= TA && nl >= TL) {
          if (ng < best) best <- ng
          next
        }

        # Prune by admissible heuristic against current best UB
        if (ng + remaining_h(nm, na, nl) >= best) next

        nkey <- paste(nm, na, nl, sep = "|")
        cur <- next_layer$get(nkey)
        if (is.null(cur) || ng < cur) {
          next_layer$set(nkey, ng)
        }
      }
    }

    total_states <- total_states + layer$size()
    layer <- next_layer
    turn_taken <- t

    if (t %% 10L == 0L || t <= 20L) {
      cat(sprintf("    turn %d  open=%d  best=%d\n",
                  t, layer$size(), best))
      flush.console()
    }
  }

  list(min_potions = best, turns_walked = turn_taken,
       states_processed = total_states)
}

results <- data.frame(seed = integer(0), ub = integer(0), optimum = integer(0),
                      states = integer(0), turns = integer(0), seconds = numeric(0))

for (k in seq_len(n_trials)) {
  seed <- seed_start + k - 1L
  set.seed(seed)
  orders_seq <- matrix(0L, nrow = N_TURNS_MAX, ncol = 3L)
  for (t in seq_len(N_TURNS_MAX)) {
    orders_seq[t, ] <- sample_orders(3L)
  }

  ub <- upper_bound_from_policy(orders_seq)
  cat(sprintf("seed %d: UB(two_plus_lye_bot) = %d. running DP...\n", seed, ub))
  flush.console()

  t0 <- Sys.time()
  res <- dp_min(orders_seq, ub)
  elapsed <- as.numeric(Sys.time() - t0, units = "secs")

  cat(sprintf("seed %d: OPT=%d  (saved %d below UB)  states=%d  turns=%d  %.1fs\n",
              seed, res$min_potions, ub - res$min_potions,
              res$states_processed, res$turns_walked, elapsed))
  flush.console()

  results <- rbind(results, data.frame(
    seed = seed, ub = ub, optimum = res$min_potions,
    states = res$states_processed, turns = res$turns_walked, seconds = elapsed
  ))
  gc(verbose = FALSE)
}

utils::write.csv(results, out_csv, row.names = FALSE)
cat(sprintf("\nwrote %s\n", out_csv))
print(results)
