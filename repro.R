RESIN <- matrix(c(
  10,0,0, 0,10,0, 0,0,10, 10,10,0, 10,0,10,
  10,10,0, 0,10,10, 10,0,10, 0,10,10, 10,10,10
), ncol = 3, byrow = TRUE)
W <- c(5,5,5,4,4,4,4,4,4,3)
TARGET <- c(45138, 39220, 52684)
BONUS <- c(1, 1.2, 1.4)

sim_all_lye <- function() {
  resin <- c(0, 0, 0)
  brewed <- 0L
  orders <- sample.int(10, 3, replace = TRUE, prob = W)
  repeat {
    if (all(resin >= TARGET)) return(brewed)
    if (all(RESIN[orders, 3] > 0)) {
      slots <- c(1L, 2L, 3L); n <- 3L
    } else {
      d <- pmax(TARGET - resin, 0)
      slots <- which.max(drop(RESIN[orders, ] %*% d)); n <- 1L
    }
    resin <- resin + colSums(RESIN[orders[slots], , drop = FALSE]) * BONUS[n]
    brewed <- brewed + n
    orders[slots] <- sample.int(10, n, replace = TRUE, prob = W)
  }
}

set.seed(1)
t0 <- Sys.time()
results <- integer(50)
for (i in seq_along(results)) {
  results[i] <- sim_all_lye()
  cat(sprintf("trial %d: %d potions\n", i, results[i]))
}
cat(sprintf("\nMean: %.0f, time %.1fs\n", mean(results),
            as.numeric(Sys.time() - t0, units = "secs")))
