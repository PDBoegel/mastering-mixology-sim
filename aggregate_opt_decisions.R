suppressPackageStartupMessages({ library(dplyr) })

parts <- list.files(".", pattern = "^opt_decisions_p.*\\.csv$", full.names = TRUE)
log_df <- do.call(rbind, lapply(parts, utils::read.csv))

per_trial <- log_df |>
  dplyr::group_by(trial) |>
  dplyr::summarise(potions = sum(n), turns = dplyr::n(), .groups = "drop")

cat(sprintf("\n=== Verified-optimal (two_plus_lye_bot) over %d sequences ===\n",
            nrow(per_trial)))
cat(sprintf("Potions per run: mean=%.0f  median=%.0f  min=%d  max=%d  p10=%.0f  p90=%.0f\n\n",
            mean(per_trial$potions),
            stats::median(per_trial$potions),
            min(per_trial$potions),
            max(per_trial$potions),
            stats::quantile(per_trial$potions, 0.10),
            stats::quantile(per_trial$potions, 0.90)))

log_df$action <- dplyr::case_when(
  log_df$n == 3L ~ "ALL3",
  log_df$n == 2L ~ "2",
  TRUE           ~ "1"
)

cat("=== Overall action mix ===\n")
print(round(prop.table(table(log_df$action)) * 100, 1))
cat("\n")

cat("=== Decision by hand signature (M-givers / A-givers / L-givers) ===\n")
hand_summary <- log_df |>
  dplyr::group_by(hand) |>
  dplyr::summarise(
    n_decisions = dplyr::n(),
    pct_1       = round(100 * mean(action == "1"), 1),
    pct_2       = round(100 * mean(action == "2"), 1),
    pct_all3    = round(100 * mean(action == "ALL3"), 1),
    .groups = "drop"
  ) |>
  dplyr::arrange(dplyr::desc(n_decisions))
print(hand_summary, n = Inf)

log_df$max_def <- pmax(log_df$d_mox, log_df$d_aga, log_df$d_lye)
log_df$phase   <- cut(log_df$max_def,
                     breaks = c(-1, 1000, 10000, 25000, 50000, Inf),
                     labels = c("<1k (endgame)", "1k-10k", "10k-25k",
                                "25k-50k", ">50k (start)"))

cat("\n=== Action mix by max-deficit bucket ===\n")
print(round(prop.table(table(log_df$phase, log_df$action), margin = 1) * 100, 1))

log_df$bottleneck <- c("mox","aga","lye")[
  apply(log_df[, c("d_mox","d_aga","d_lye")], 1, which.max)
]
cat("\n=== Bottleneck colour across decisions ===\n")
print(round(prop.table(table(log_df$bottleneck)) * 100, 1))

utils::write.csv(hand_summary, "optimal_hand_summary.csv", row.names = FALSE)
cat("\nWrote optimal_hand_summary.csv\n")
