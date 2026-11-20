#!/usr/bin/env Rscript
# Render the LS6 runtime and storage table from the saved batch inventories.
# Run scripts/collect_ls6_csv_sizes.sh separately on LS6 before rendering.
library(grid)

script <- sub("^--file=", "", commandArgs()[startsWith(commandArgs(), "--file=")][1])
repo <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
source(file.path(repo, "scripts/manuscript_figure_legends.R"))

args <- commandArgs(trailingOnly = TRUE)
arg <- function(key, default) {
  prefix <- paste0(key, "=")
  values <- args[startsWith(args, prefix)]
  if (length(values)) substring(tail(values, 1), nchar(prefix) + 1L) else default
}
root <- arg("--data-dir", file.path(repo, "LS6_RmSweep_TEST"))
figure_dir <- arg("--figure-dir", file.path(repo, "figures/manuscript"))
stem <- "LS6_runtime_storage"

csv_sizes_path <- file.path(root, "ls6_csv_sizes.csv")
if (!file.exists(csv_sizes_path)) {
  stop("Missing ", csv_sizes_path, ". Run scripts/collect_ls6_csv_sizes.sh separately on LS6 ",
    "and copy ls6_csv_sizes.csv into the data directory. See scripts/README.md.", call. = FALSE)
}
metadata <- read.csv(file.path(root, "metadata_master.csv"))

scenario_labels <- c(
  "No interventions", "Antiviral", "NPI", "Vaccination", "All interventions"
)
scenario_by_flags <- c(`000` = 1L, `010` = 2L, `001` = 3L, `100` = 4L, `111` = 5L)
metadata$scenario <- unname(scenario_by_flags[with(metadata,
  paste0(as.integer(vaccine_used), as.integer(antiviral_used), as.integer(npi_used)))])
state_codes <- setNames(c(state.abb, "DC"), c(gsub(" ", "-", state.name), "District-of-Columbia"))
metadata$state <- unname(state_codes[metadata$geo_region])
stopifnot(nrow(metadata) == 255L, !anyNA(metadata$state), !anyNA(metadata$scenario),
  all(table(metadata$state, metadata$scenario) == 1L), all(metadata$geo_level == "county"),
  all(metadata$complete_realization_count == 100L), all(metadata$sim_days == 200L))

parquet_components <- metadata[c("network_parquet_bytes", "nodes_parquet_bytes", "sim_times_parquet_bytes")]
stopifnot(all(parquet_components > 0), all(is.finite(metadata$mean_run_time_seconds)),
  all(metadata$mean_run_time_seconds > 0))
metadata$parquet_bytes <- rowSums(parquet_components)

csv_sizes <- read.csv(csv_sizes_path)
csv_key <- with(csv_sizes, paste(scenario_hash, batch_num))
metadata_key <- with(metadata, paste(scenario_hash, batch_num))
stopifnot(!anyDuplicated(csv_key), !anyDuplicated(metadata_key), setequal(csv_key, metadata_key))
csv_sizes <- csv_sizes[match(metadata_key, csv_key), ]
scenario_codes <- c("NONE", "ANTIVIRAL", "NPI", "VACCINE", "ALL_INTERVENTIONS")
csv_components <- csv_sizes[c("network_csv_bytes", "nodes_csv_bytes", "sim_times_csv_bytes")]
stopifnot(all(csv_sizes$geo_region == metadata$geo_region),
  all(csv_sizes$scenario == scenario_codes[metadata$scenario]),
  all(csv_sizes$csv_size_status == "ok"), all(csv_components > 0),
  all(csv_sizes$total_csv_bytes == rowSums(csv_components)))
metadata$csv_bytes <- csv_sizes$total_csv_bytes

format_runtime <- function(seconds) {
  seconds <- round(seconds)
  sprintf("%d:%02d", seconds %/% 60, seconds %% 60)
}

format_storage <- function(bytes) {
  megabytes <- round(bytes / 1e6)
  gigabytes <- bytes / 1e9
  ifelse(megabytes < 100, paste(megabytes, "MB"),
    paste(ifelse(gigabytes < 1, round(bytes / 1e8) / 10, round(gigabytes)), "GB"))
}

states <- unique(metadata[c("state", "geo_node_count")])
stopifnot(nrow(states) == 51L, !anyDuplicated(states$state))
states <- states[order(states$geo_node_count, states$state), ]
display <- cbind(states$state, as.character(states$geo_node_count))
for (i in seq_along(scenario_labels)) {
  batch <- metadata[metadata$scenario == i, ]
  batch <- batch[match(states$state, batch$state), ]
  display <- cbind(display, format_runtime(batch$mean_run_time_seconds),
    format_storage(batch$csv_bytes), format_storage(batch$parquet_bytes))
}

navy <- "#153247"
light_blue <- "#e0ebf0"
stripe <- "#f7f9fa"
ink <- "#1e2b34"
column_weights <- c(.76, 1.04, rep(c(1.20, .925, .925), 5L))
x_edges <- c(0, cumsum(column_weights)) / sum(column_weights)
x_centers <- head(x_edges, -1) + diff(x_edges) / 2
width <- 10
body_size <- 10.5
cell_padding <- 2.25
row_height <- (body_size + 2 * cell_padding) / 72
group_height <- .29
label_height <- .49
table_height <- function(row_count) {
  row_count * row_height + group_height + label_height
}
inch <- function(x) unit(x, "inches")

draw_rect <- function(x, y, width, height, fill) {
  grid.rect(x, inch(y), width, inch(height), gp = gpar(fill = fill, col = NA))
}
draw_text <- function(text, x, y, size, color = ink, bold = FALSE, just = "center") {
  grid.text(text, x, inch(y), just = just, gp = gpar(fontfamily = "Helvetica",
    fontsize = size, col = color, fontface = if (bold) "bold" else "plain", lineheight = 1.05))
}

draw_table <- function(page_rows) {
  top <- table_height(nrow(page_rows))
  label_top <- top - group_height
  body_top <- label_top - label_height
  row_y <- body_top - (seq_len(nrow(page_rows)) - .5) * row_height

  draw_rect(.5, top - group_height / 2, 1, group_height, navy)
  draw_rect(.5, label_top - label_height / 2, 1, label_height, light_blue)
  draw_rect(.5, row_y, 1, row_height, rep(c("white", stripe), length.out = nrow(page_rows)))

  group_starts <- seq(3L, ncol(page_rows), by = 3L)
  for (first in group_starts[c(2L, 4L)]) {
    edges <- x_edges[c(first, first + 3L)]
    draw_rect(mean(edges), row_y, diff(edges), row_height,
      rep(c("#f8fafb", "#f0f5f7"), length.out = nrow(page_rows)))
  }
  for (i in seq_along(group_starts)) {
    first <- group_starts[i]
    draw_text(scenario_labels[i], mean(x_edges[c(first, first + 3L)]),
      top - group_height / 2, 11, "white", TRUE)
  }
  for (edge in x_edges[group_starts]) {
    grid.segments(edge, inch(body_top - nrow(page_rows) * row_height), edge, inch(label_top),
      gp = gpar(col = "#cedbe1", lwd = .63))
    grid.segments(edge, inch(label_top), edge, inch(top), gp = gpar(col = "#587181", lwd = .63))
  }

  label_y <- label_top - label_height / 2
  draw_text(c("State", "Counties"), x_centers[1:2], label_y, 9.6, navy, TRUE)
  runtime_label_x <- x_centers[group_starts] + .006
  draw_text(rep("1 Sim Mean", 5L), runtime_label_x, label_y + .135, 8.8, navy, TRUE)
  draw_text(rep("Runtime", 5L), runtime_label_x, label_y, 8.8, navy, TRUE)
  draw_text(rep("min:sec", 5L), runtime_label_x, label_y - .135, 7.8, navy)
  draw_text(rep("CSV", 5L), x_centers[group_starts + 1L], label_y, 8.8, navy, TRUE)
  draw_text(rep("Parquet", 5L), x_centers[group_starts + 2L], label_y, 8.8, navy, TRUE)
  for (column in seq_len(ncol(page_rows))) {
    if (column == 1L) {
      draw_text(page_rows[, column], x_centers[column], row_y, body_size, navy, TRUE)
    } else if (column == 2L) {
      draw_text(page_rows[, column], x_edges[column + 1L] - .011, row_y, body_size, just = "right")
    } else if (column %in% group_starts) {
      draw_text(page_rows[, column], x_centers[column] + .012, row_y, body_size, just = "right")
    } else {
      draw_text(page_rows[, column], x_centers[column], row_y, body_size)
    }
  }
}

split_after <- ceiling(nrow(display) / 2)
pages <- list(display[seq_len(split_after), , drop = FALSE],
  display[seq.int(split_after + 1L, nrow(display)), , drop = FALSE])
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)
png_device <- if (requireNamespace("ragg", quietly = TRUE)) ragg::agg_png else grDevices::png
for (i in seq_along(pages)) {
  page_rows <- pages[[i]]
  png_device(file.path(figure_dir, sprintf("%s_part_%d.png", stem, i)), width = width,
    height = table_height(nrow(page_rows)), units = "in", res = 450, background = "white")
  grid.newpage()
  draw_table(page_rows)
  invisible(dev.off())
}

write_manuscript_legend(figure_dir, stem, "Lonestar6 simulation runtime and output size", c(
  "Scope" = paste("Each of the 50 states and the District of Columbia has five scenario batches,",
    "with 100 completed realizations per batch. Each realization was configured for 200 simulation days.",
    "Rows are ordered by the number of county or county-equivalent nodes in the simulation,",
    "from fewest to most, with ties ordered by postal abbreviation. The NPI scenario applies a",
    "weekend mobility decrease as its nonpharmaceutical intervention."),
  "Single-simulation runtime" = paste("1 Sim Mean Runtime is the arithmetic mean of the 100 recorded",
    "per-realization elapsed times in each state and scenario. It is displayed as minutes and",
    "seconds (min:sec), rounded to the nearest second. The times were verified against the",
    "corresponding timing Parquet files."),
  "Parallel wall-clock time" = paste("The timing files contain durations for individual realizations.",
    "Batch and job wall-clock durations could not be determined from the local archive.",
    "LS6 scheduler accounting would provide elapsed time for a Slurm job. Per-batch wall time",
    "would require start and finish timestamps for each state-scenario batch."),
  "Output size" = paste("CSV and Parquet sizes each sum the network, county-level and timing files",
    "for the full 100-realization batch. CSV sizes were measured from the original files on LS6",
    "in TACC_FILES and Rm_search. Sizes are shown in whole megabytes when the rounded value is",
    "below 100 MB, tenths of a gigabyte up to 1 GB, and whole gigabytes from 1 GB onward.",
    "One MB equals one million bytes and one GB equals one billion bytes."),
  "Sources" = paste("LS6_RmSweep_TEST/metadata_master.csv, ls6_csv_sizes.csv and batch Parquet files",
    "under LS6_RmSweep_TEST/sim_data/. CSV sizes were matched by scenario hash and batch ID.")))
