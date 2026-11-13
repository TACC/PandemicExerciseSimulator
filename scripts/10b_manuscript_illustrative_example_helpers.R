# Compact count axes, preserving fractional K/M/B values without trailing zeros.
compact_axis_label <- function(x) {
  labels <- scales::label_number(scale_cut=scales::cut_short_scale())(x)
  labels <- sub("(\\.[0-9]*[1-9])0+([KMB]?)$", "\\1\\2", labels)
  sub("\\.0+([KMB]?)$", "\\1", labels)
}

# Focused baseline diagnostic, using existing simulations only.
plot_10b_baseline <- function(states, settings, out, figure_dir) {
  baseline <- states %>% filter(scenario == "high") %>% arrange(model, sim_id, day) %>%
    group_by(model, sim_id) %>% mutate(
      new_infections = pmax(0, lag(S, default = first(S)) - S),
      cumulative_new = first(S) - S,
      final_new = last(cumulative_new)) %>% ungroup()
  runs <- baseline %>% group_by(model, sim_id) %>% summarise(
    initial_exposed = first(E), new_infections = last(cumulative_new),
    peak_I = max(I), peak_I_day = day[which.max(I)],
    last_recorded_day = first(last_recorded_day),
    any_secondary_infections = new_infections > 1e-6,
    peak_I_exceeds_seed = peak_I > initial_exposed + 1e-6, .groups = "drop")
  stopifnot(all(table(runs$model) == settings$realizations),
    all(abs(runs$initial_exposed - settings$high_exposed) < 1e-6),
    all(baseline$cumulative_new >= -1e-6))
  write.csv(runs, file.path(out, "baseline_10k_run_diagnostics.csv"), row.names = FALSE)
  write.csv(baseline, file.path(out, "baseline_10k_daily_diagnostics.csv"), row.names = FALSE)
  extrema <- runs %>% group_by(model) %>% arrange(new_infections, sim_id) %>%
    summarise(min_id = first(sim_id), max_id = last(sim_id), .groups = "drop")
  plotted <- baseline %>% select(model, sim_id, day, I, new_infections, cumulative_new, final_new) %>%
    pivot_longer(c(I, new_infections, cumulative_new), names_to = "metric", values_to = "people")
  metrics <- c("I", "new_infections", "cumulative_new")
  plotted$panel <- factor(paste(plotted$model, plotted$metric, sep = "_"),
    levels = as.vector(t(outer(c("deterministic", "stochastic"), metrics, paste, sep = "_"))),
    labels = c("Deterministic: infectious (I)", "Deterministic: new infections / day",
      "Deterministic: cumulative new infections", "Stochastic: infectious (I)",
      "Stochastic: new infections / day", "Stochastic: cumulative new infections"))
  highlighted <- inner_join(plotted, extrema, by = "model") %>%
    filter(sim_id == min_id | sim_id == max_id)
  caption <- paste0("All ", settings$realizations, " runs per model; color = final infections generated beyond the initial ",
    format(settings$high_exposed, big.mark = ","), " exposures. Bold lines: smallest/largest final totals.\n",
    "Binomial travel in both models. Terminal I values below the simulator stopping threshold are held after early termination; new infections are zero afterward.")
  p <- ggplot(plotted, aes(day, people, group = interaction(model, sim_id), color = final_new)) +
    geom_line(linewidth = .35, alpha = .30) +
    geom_line(data = highlighted, linewidth = .8, alpha = 1) +
    facet_wrap(~panel, ncol = 3, scales = "free_y") +
    scale_color_viridis_c(option = "C", name = "Final additional infections", labels = scales::label_comma()) +
    scale_x_continuous(limits = c(0, settings$days), breaks = pretty(c(0, settings$days), n = 4)) +
    scale_y_continuous(limits = c(0, NA), labels = compact_axis_label) +
    labs(title = "Delaware baseline: every high-seed realization",
      subtitle = paste0("R0 input = ", settings$r0 %||10b% 1.2, "; initial exposed = ",
        format(settings$high_exposed, big.mark = ","), "; no interventions; no waning immunity"),
      x = "Simulation day", y = "People", caption = caption) +
    theme_bw(base_size = 11) + theme(legend.position = "bottom",
      panel.grid.minor = element_blank(), strip.text = element_text(hjust = 0, face = "bold", size = 10),
      plot.caption = element_text(hjust = 0, size = 9)) +
    guides(color = guide_colorbar(barwidth = grid::unit(8, "cm")))
  dir.create(figure_dir, recursive=TRUE, showWarnings = FALSE)
  for (ext in c("png", "pdf")) ggsave(file.path(figure_dir, paste0("baseline_10k_spaghetti.", ext)),
    p, width = 16, height = 8.5, dpi = 200)
  totals <- runs %>% group_by(model) %>% summarise(
    runs = n(), with_new_infections = sum(any_secondary_infections),
    peak_above_seed = sum(peak_I_exceeds_seed),
    new_min = min(new_infections), new_median = median(new_infections), new_max = max(new_infections),
    .groups = "drop")
  print(totals, width = Inf)
  invisible(runs)
}
`%||10b%` <- function(x, y) if (is.null(x)) y else x

# Mean-field linearization of the actual local/travel force of infection at
# full susceptibility. Not the stochastic extinction probability or a fitted R0.
diagnose_10b_reproduction <- function(settings, repo, out) {
  data_root <- if (dir.exists(file.path(out,"data_snapshot"))) file.path(out,"data_snapshot") else file.path(repo,"data/Delaware")
  pop <- as.matrix(read.csv(file.path(data_root, "county_pop_by_age_Delaware_2020-2024ACS.csv"))[, -1])
  contact <- as.matrix(read.csv(file.path(data_root, "contact_matrix_Delaware_Mistry2021_all.csv"), header = FALSE))
  flow <- as.matrix(read.csv(file.path(data_root, "Delaware_Q4-2019_mobility-matrix.csv"), header = FALSE))
  input <- read_json(file.path(out, "inputs/INPUT_high_deterministic_Delaware.json"), simplifyVector = TRUE)
  pars <- input$travel_model$parameters
  stopifnot(as.numeric(pars$rho) == 1, all(as.numeric(pars$flow_reduction) == 1),
    as.numeric(pars$traveling_compartments$I) == .2, as.numeric(pars$transmitting_compartments$I) == 1)
  r0 <- as.numeric(input$disease_model$parameters$R0)
  spectral_radius <- function(x) max(Re(eigen(x, only.values = TRUE)$values))
  n <- rowSums(pop)
  proportions <- pop / n
  # Untagged saved batches predate the deterministic normalization change.
  denominators <- input$metadata_tags$local_contact_denominators %||10b%
    list(deterministic = "total_node_pop", stochastic = "total_node_pop")
  result <- bind_rows(lapply(names(denominators), function(model) {
    denominator <- denominators[[model]]
    stopifnot(denominator %in% c("total_node_pop", "contacted_age_population"))
    K <- matrix(0, nrow = 15, ncol = 15)
    for (i in 1:3) for (j in 1:3) {
      block <- if (i == j && denominator == "contacted_age_population")
        diag(pop[i, ]) %*% contact %*% diag(1 / pop[i, ]) else if (i != j &&
          identical(input$metadata_tags$travel_contact_denominator, "contacted_age_population")) {
          flow[i, j] * diag(pop[i, ]) %*% contact %*% diag(1 / pop[j, ]) +
            .2 * flow[j, i] * diag(pop[i, ]) %*% contact %*% diag(1 / pop[i, ])
        } else {
          weight <- if (i == j) 1 else n[i] / n[j] * flow[i, j] + .2 * flow[j, i]
          weight * diag(proportions[i, ]) %*% contact
        }
      K[(5*i-4):(5*i), (5*j-4):(5*j)] <- r0 / spectral_radius(contact) * block
    }
    network <- spectral_radius(K)
    data.frame(model = model, local_contact_denominator = denominator, input_R0 = r0,
      linearized_network_reproduction = network,
      approximate_input_R0_for_unit_reproduction = r0 / network)
  }))
  write.csv(result, file.path(out, "baseline_reproduction_diagnostic.csv"), row.names = FALSE)
  print(result)
  invisible(result)
}

rerun_10b_deterministic_baseline <- function(repo, original_out, python = "", plots_only = FALSE, figure_dir=file.path(repo,"figures/manuscript")) {
  settings <- read_json(file.path(original_out, "comparison_settings.json"), simplifyVector = TRUE)
  run_out <- file.path(original_out, "mistry_deterministic_baseline")
  config <- read_json(file.path(original_out, "inputs/INPUT_high_deterministic_Delaware.json"), simplifyVector = FALSE)
  stopifnot(config$disease_model$identity == "seirs-deterministic",
    as.numeric(config$disease_model$parameters$R0) == 1.2)
  config$output_dir_path <- file.path(run_out, "simulations")
  config$batch_num <- "mistry_high_deterministic"
  config$metadata_tags$local_contact_denominators <- list(
    deterministic = "contacted_age_population", stochastic = "contacted_age_population")
  config$metadata_tags$travel_contact_denominator <- "contacted_age_population"
  input_path <- file.path(run_out, "inputs/INPUT_high_deterministic_Delaware.json")
  network_path <- file.path(config$output_dir_path, "network_batch-mistry_high_deterministic.csv")
  if (!plots_only) {
    if (dir.exists(config$output_dir_path) && length(list.files(config$output_dir_path, all.files = TRUE, no.. = TRUE)))
      stop("Existing rerun output; use --rerun-deterministic-baseline --plots-only")
    dir.create(dirname(input_path), recursive = TRUE, showWarnings = FALSE)
    dir.create(config$output_dir_path, recursive = TRUE, showWarnings = FALSE)
    write_json(config, input_path, pretty = TRUE, auto_unbox = TRUE, null = "null")
    write_json(settings, file.path(run_out, "comparison_settings.json"), pretty = TRUE, auto_unbox = TRUE)
    file.copy(file.path(repo, "src/models/disease/DeterministicSEIRS.py"),
      file.path(run_out, "executed_DeterministicSEIRS.py"), overwrite = FALSE)
    cache <- file.path(run_out, "matplotlib_cache")
    dir.create(cache, showWarnings = FALSE)
    Sys.setenv(MPLCONFIGDIR = cache)
    sim_args <- c(shQuote(file.path(repo, "src/simulator.py")), "-l", "WARNING", "-d", settings$days,
      "-i", shQuote(input_path))
    log <- file.path(run_out, "simulation.log")
    message("Running corrected deterministic baseline: ", settings$realizations, " realizations; ", settings$days, " days")
    status <- if (nzchar(python)) system2(python, sim_args, stdout = log, stderr = log) else
      system2("poetry", c("-C", shQuote(repo), "run", "python", sim_args), stdout = log, stderr = log)
    if (status != 0) stop("Rerun failed; see ", log)
  }
  # Replotting must describe the implementation used for the saved run.
  config <- read_json(input_path, simplifyVector = FALSE)
  travel_description <- if (identical(config$metadata_tags$travel_contact_denominator, "contacted_age_population"))
    "Local and travel transmission use age-cohort denominators in the new runs." else
    "New runs change local transmission only; binomial travel retains its previous normalization."
  original <- read.csv(file.path(original_out, "statewide_trajectories.csv")) %>%
    filter(scenario == "high", model == "deterministic")
  corrected <- read.csv(network_path) %>% arrange(sim_id, day)
  check <- corrected %>% group_by(sim_id) %>% summarise(
    contiguous = identical(as.integer(day), seq.int(0L, max(day))),
    conserved = max(abs(S + E + I + R - settings$state_population)) < 1e-5,
    valid_stop = last(day) == settings$days || last(E + I) <= .99 + 1e-8, .groups = "drop")
  stopifnot(nrow(check) == settings$realizations, all(check$contiguous), all(check$conserved), all(check$valid_stop),
    all(is.finite(as.matrix(corrected[c("S", "E", "I", "R")]))),
    all(as.matrix(corrected[c("S", "E", "I", "R")]) >= -1e-8))
  corrected <- corrected %>% group_by(sim_id) %>% mutate(last_recorded_day = max(day)) %>%
    complete(day = 0:settings$days) %>% fill(S, E, I, R, last_recorded_day, .direction = "down") %>% ungroup()
  original$denominator <- "Previous: county population"
  corrected$denominator <- "Mistry: contacted age population"
  combined <- bind_rows(original, corrected) %>% arrange(denominator, sim_id, day) %>%
    group_by(denominator, sim_id) %>% mutate(new_infections = pmax(0, lag(S, default = first(S)) - S),
      cumulative_new = first(S) - S) %>% ungroup()
  stopifnot(all(table(combined$denominator, combined$day) == settings$realizations),
    all(combined$E[combined$day == 0] == settings$high_exposed))
  write.csv(combined, file.path(run_out, "denominator_comparison_trajectories.csv"), row.names = FALSE)
  metrics <- combined %>% group_by(denominator, sim_id) %>% summarise(
    peak_I = max(I), peak_I_day = day[which.max(I)], final_I = last(I),
    additional_infections = last(cumulative_new), ever_infected = settings$state_population - last(S),
    .groups = "drop")
  write.csv(metrics, file.path(run_out, "denominator_comparison_metrics.csv"), row.names = FALSE)
  series <- bind_rows(
    combined %>% transmute(denominator, sim_id, day, panel = "A  Infectious (I)", people = I),
    combined %>% transmute(denominator, sim_id, day, panel = "B  Infectious (I): log1p", people = log1p(I)),
    combined %>% transmute(denominator, sim_id, day, panel = "C  New infections / day", people = new_infections),
    combined %>% transmute(denominator, sim_id, day, panel = "D  Additional infections since seeding", people = cumulative_new))
  median_series <- series %>% group_by(denominator, day, panel) %>% summarise(people = median(people), .groups = "drop")
  p <- ggplot(series, aes(day, people, color = denominator, group = interaction(denominator, sim_id))) +
    geom_line(alpha = .12, linewidth = .3) +
    geom_line(data = median_series, aes(group = denominator), linewidth = .85) +
    facet_wrap(~panel, ncol = 2, scales = "free_y") +
    scale_color_manual(values = c("Previous: county population" = "#0072B2", "Mistry: contacted age population" = "#D55E00")) +
    scale_x_continuous(limits = c(0, settings$days)) + scale_y_continuous(limits = c(0, NA), labels = compact_axis_label) +
    labs(title = "Delaware deterministic SEIR: transmission denominator comparison",
      subtitle = paste0("R0 = 1.2; 10,000 initial exposed in New Castle; ", settings$realizations, " realizations per version"),
      x = "Simulation day", y = "People (panel B: ln[1 + I])", color = NULL,
      caption = paste0("Thin lines: individual runs; bold: median. ", travel_description,
        "\nBinomial travel remains stochastic; random draws differ between batches. New-infection counts exclude the initial seed.",
        "\nPanel B uses transformed values. Terminal states are held after early stops.")) +
    theme_bw(base_size = 11) + theme(legend.position = "bottom", panel.grid.minor = element_blank(),
      strip.text = element_text(hjust = 0, face = "bold"), plot.caption = element_text(hjust = 0))
  dir.create(figure_dir, recursive=TRUE, showWarnings = FALSE)
  for (ext in c("png", "pdf")) ggsave(file.path(figure_dir, paste0("baseline_10k_denominator_comparison.", ext)),
    p, width = 13, height = 9.5, dpi = 200)
  diagnose_10b_reproduction(settings, repo, run_out)
  print(metrics %>% group_by(denominator) %>% summarise(
    simulations = n(), peak_I_median = median(peak_I), peak_day_median = median(peak_I_day),
    additional_infections_median = median(additional_infections),
    ever_infected_median = median(ever_infected), .groups = "drop"), width = Inf)
  message("Saved corrected baseline comparison in ", run_out)
}

# Document the normal repository entry point, without a separate bundled runner.
write_10b_example_readme <- function(out) {
  writeLines(c(
    "# Delaware manuscript example",
    "",
    "Run the example from the repository root using the single main script:",
    "",
    "```sh",
    "Rscript scripts/10b_manuscript_illustrative_example.R",
    "```",
    "",
    "The main file uses 10b_manuscript_illustrative_example_helpers.R alongside it, the simulator under src/, and the repository's Delaware data. It creates all 14 scenario/model batches locally in MANUSCRIPT_ILLUSTRATIVE_EXAMPLE_TEST/. Running the same command again validates and resumes completed batches, then regenerates figures. No other experiment folder or separate reviewer runner is used.",
    "",
    "The defaults are 100 realizations per model/scenario for 200 days: 1K/10K initial exposures; 100K/1M vaccine doses at 60% effectiveness released on days 30-50 with a 14-day lag; school closure on days 30-50; and 10K/100K antiviral courses on day 30. Every scenario uses county-specific age risk ratios matched by FIPS.",
    "",
    "To regenerate only the figures from saved simulations:",
    "",
    "```sh",
    "Rscript scripts/10b_manuscript_illustrative_example.R --plots-only",
    "```",
    "",
    "Use --workers=8 to set parallel workers, --prepare-only to write/check inputs, or --output-dir=PATH for a fresh experiment with different parameters. Python dependencies use the repository Poetry environment; an existing environment can be selected with --python=/path/to/python. R packages required are jsonlite, dplyr, tidyr, ggplot2, cowplot, and sf.",
    "",
    "## Contents",
    "",
    "simulations/ contains all 14 local batches; inputs/ contains their configurations. data_snapshot/ contains the actual scientific CSVs and county boundaries. source_snapshot/src/ is a passive record of the Python implementation used for validation, not another execution location. The saved manifest uses experiment-relative output paths.",
    "",
    "All manuscript PNG/PDF figures are written directly to the repository figures/manuscript/ directory. statewide_2x2_linear.png and .pdf are the main composite; statewide_2x2_log1p provides the alternate scale; statewide_2x2_notes.pdf contains the notes. The main script also invokes 10c_manuscript_illustrative_inputs.R to regenerate Delaware_inputs_5panel.png/.pdf and its caption there. Ancillary explanatory input tables and boundaries remain under this experiment's input_figure/.",
    "",
    "Checks validate initial county-age risk allocations, population conservation, complete time series or valid epidemic extinction, vaccine administration bounds, and treatment timing. Original simulation metadata preserves creation-time paths and random seeds; fresh simulations use independent seeds."
  ),file.path(out,"README.md"))
}
