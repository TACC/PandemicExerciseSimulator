# Delaware statewide 2x2 manuscript illustration; configuration and CLI options below.
suppressPackageStartupMessages({
  library(jsonlite); library(dplyr); library(tidyr); library(ggplot2); library(cowplot)
})
args <- commandArgs(trailingOnly = TRUE)
arg <- function(key, default) {
  x <- args[startsWith(args, paste0(key, "="))]
  if (length(x)) substring(tail(x, 1), nchar(key) + 2) else default
}
integer_arg <- function(key, default, minimum) {
  x <- suppressWarnings(as.numeric(arg(key, default)))
  if (length(x) != 1 || !is.finite(x) || x < minimum || x != floor(x))
    stop(key, " must be an integer >= ", minimum)
  as.integer(x)
}
script <- sub("^--file=", "", commandArgs()[startsWith(commandArgs(), "--file=")][1])
repo <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
days <- integer_arg("--days", 200, 1)
realizations <- integer_arg("--realizations", 100, 2)
workers <- integer_arg("--workers", 4, 1)
vaccine_effectiveness <- suppressWarnings(as.numeric(arg("--vaccine-effectiveness", "0.60")))
if (length(vaccine_effectiveness) != 1 || !is.finite(vaccine_effectiveness) ||
    vaccine_effectiveness < 0 || vaccine_effectiveness > 1) stop("--vaccine-effectiveness must be between 0 and 1")
low_seed <- integer_arg("--low-exposed", 1000, 1)
high_seed <- integer_arg("--high-exposed", 10000, 1)
if (low_seed >= high_seed) stop("--low-exposed must be below --high-exposed")
prepare_only <- "--prepare-only" %in% args
vaccine_panel_only <- "--vaccine-panel-only" %in% args
plots_only <- "--plots-only" %in% args || vaccine_panel_only
resume <- "--resume" %in% args
if (prepare_only && plots_only) stop("Choose either --prepare-only or --plots-only")
out <- arg("--output-dir", file.path(repo, "MANUSCRIPT_ILLUSTRATIVE_EXAMPLE_TEST"))
dir.create(out, recursive = TRUE, showWarnings = FALSE)
out <- normalizePath(out, mustWork = TRUE)
# Running the same file again resumes verified local batches automatically.
resume <- resume || file.exists(file.path(out,"comparison_settings.json"))
input_dir <- file.path(out, "inputs")
figure_dir <- arg("--figure-dir",file.path(repo,"figures/manuscript"))
dir.create(input_dir, showWarnings = FALSE)
dir.create(figure_dir, recursive=TRUE, showWarnings = FALSE)
source(file.path(repo, "scripts/10b_manuscript_illustrative_example_helpers.R"))
if ("--rerun-deterministic-baseline" %in% args) {
  rerun_10b_deterministic_baseline(repo, out, python = arg("--python", ""), plots_only = plots_only, figure_dir=figure_dir)
  quit(save = "no", status = 0)
}
if ("--baseline-only" %in% args) {
  settings <- read_json(file.path(out, "comparison_settings.json"), simplifyVector = TRUE)
  saved_states <- read.csv(file.path(out, "statewide_trajectories.csv"))
  plot_10b_baseline(saved_states, settings, out, figure_dir)
  diagnose_10b_reproduction(settings, repo, out)
  quit(save = "no", status = 0)
}
# Scientific inputs are copied once into this run, then used from that snapshot.
data_snapshot <- file.path(out, "data_snapshot")
dir.create(data_snapshot, showWarnings=FALSE)
data_file <- function(name) {
  target <- file.path(data_snapshot,name)
  if (!file.exists(target)) {
    original <- normalizePath(file.path(repo,"data/Delaware",name),mustWork=TRUE)
    if (!file.copy(original,target)) stop("Could not snapshot input: ",original)
  }
  normalizePath(target,mustWork=TRUE)
}
shape_path <- arg("--county-shapefile","")
shape_snapshot <- file.path(data_snapshot,"Delaware_counties.gpkg")
if (nzchar(shape_path) && !file.exists(shape_path))
  stop("County boundary file does not exist: ",shape_path)
if (!nzchar(shape_path)) {
  candidates <- c(shape_snapshot,file.path(out,"input_figure/Delaware_counties.gpkg"),
    file.path(repo,"data/Delaware/Delaware_counties.gpkg"))
  available <- candidates[file.exists(candidates)]
  if (length(available)) shape_path <- available[1]
}
if (nzchar(shape_path) && !file.exists(shape_snapshot) && grepl("[.]gpkg$",shape_path,ignore.case=TRUE)) {
  if (!file.copy(shape_path,shape_snapshot)) stop("Could not snapshot county boundaries")
  shape_path <- shape_snapshot
}
# With no local boundary cache, 10c fetches Census boundaries when plotting.
population_file <- data_file("county_pop_by_age_Delaware_2020-2024ACS.csv")
pop <- read.csv(population_file, check.names = FALSE)
stopifnot(identical(as.integer(pop$fips), c(10001L, 10003L, 10005L)))
state_population <- sum(as.matrix(pop[, -1]))
vaccine_doses <- c(vax100k = 100000L, vax1m = 1000000L)
antiviral_doses <- c(antiviral10k = 10000L, antiviral100k = 100000L)
vaccine_release_days <- 30:50
vaccine_daily_doses <- lapply(vaccine_doses, function(total)
  as.integer(diff(floor((0:length(vaccine_release_days)) * total / length(vaccine_release_days)))))
vaccine_lag_days <- 14L
stopifnot(identical(vapply(vaccine_daily_doses, sum, integer(1)), vaccine_doses))
models <- c("deterministic", "stochastic")
scenarios <- c("low", "high", "vax100k", "vax1m", "closure", "antiviral10k", "antiviral100k")
empty_object <- function() structure(list(), names = character())
base <- list(output_dir_path = "GENERATE", realization_range = c("0", as.character(realizations - 1L)),
  batch_num = "GENERATE", execution = list(mode = "parallel", workers = workers),
  metadata_tags = list(creator = "PES manuscript illustrative example",
    disease = list("Illustrative flu-like illness"), sim_day_0 = NULL,
    local_contact_denominators = list(deterministic = "contacted_age_population", stochastic = "contacted_age_population"),
    travel_contact_denominator = "contacted_age_population",
    risk_ratio_scope = "county_by_age",
    notes = list("Statewide 2x2 comparison; binomial travel in both disease models; no waning immunity; county-age risks matched by FIPS.")),
  data = list(population = population_file,
    contact = data_file("contact_matrix_Delaware_Mistry2021_all.csv"),
    flow = data_file("Delaware_Q4-2019_mobility-matrix.csv"),
    high_risk_ratios = data_file("county_Delaware_high-risk-ratios-flu-only.csv")),
  disease_model = list(identity = "seirs-deterministic", parameters = list(
    compartments = c("S", "E", "I", "R"), R0 = "1.2", E_to_I_days = "1",
    I_to_R_days = "7", R_to_S_days = "0")),
  travel_model = list(identity = "binomial", parameters = list(rho = "1",
    flow_reduction = rep("1.0", 5), traveling_compartments = list(I = "0.2"),
    transmitting_compartments = list(I = "1.0"))),
  initial_exposed = list(list(county = "10003", infected = as.character(high_seed), age_group = "2")),
  non_pharma_interventions = list(), antiviral_model = empty_object(), vaccine_model = empty_object())
make_config <- function(scenario, model) {
  x <- base
  x$metadata_tags$scenario_label <- scenario
  x$initial_exposed[[1]]$infected <- as.character(if (scenario == "low") low_seed else high_seed)
  if (scenario %in% c("vax100k", "vax1m")) {
    ve <- as.character(vaccine_effectiveness)
    daily_doses <- vaccine_daily_doses[[scenario]]
    x$vaccine_model <- list(identity = "stockpile-age-risk", parameters = list(
      age_risk_priority_groups = rep("1", 5), vaccine_half_life_days = NULL,
      vaccine_capacity_proportion = "1", vaccine_adherence = rep("1", 5),
      vaccine_effectiveness = rep(ve, 5), vaccine_eff_lag_days = vaccine_lag_days,
      vaccine_stockpile = lapply(seq_along(vaccine_release_days), function(i)
        list(day = as.character(vaccine_release_days[i]), amount = as.character(daily_doses[i])))))
  }
  if (scenario == "closure") {
    # The daily disease model at time d reads schedule[d-1]. Index 29 therefore
    # affects output updates on simulation days 30 through 50 inclusive.
    x$non_pharma_interventions <- list(list(
      name = "School closure and reduced adult contacts", day = "29", duration = "21", location = "0",
      effectiveness = c("0", "0.9", "0.5", "0.5", "0.5")))
    x$metadata_tags$npi_active_simulation_days <- list(first = 30L, last = 50L)
  }
  if (scenario %in% c("antiviral10k", "antiviral100k")) {
    x$disease_model$parameters$compartments <- c("S", "E", "I", "T", "R")
    x$disease_model$parameters$T_to_R_days <- "5"
    x$disease_model$parameters$rel_inf_T_to_I <- "0.5"
    # Both travel pressure pathways need half the I weight for treated infection.
    x$travel_model$parameters$traveling_compartments$T <- "0.1"
    x$travel_model$parameters$transmitting_compartments$T <- "0.5"
    x$antiviral_model <- list(identity = "stockpile-age-risk", parameters = list(
      age_risk_priority_groups = rep("1", 5), compartment_priority = list("I"),
      antiviral_capacity_proportion = "1", antiviral_half_life_days = NULL,
      antiviral_stockpile = list(list(day = "30", amount = as.character(antiviral_doses[[scenario]])))))
    # Omit adherence: treat prevalent I at release, then later eligible I while inventory lasts.
  }
  x$disease_model$identity <- paste0("seirs-", model)
  key <- paste(scenario, model, sep = "_")
  x$output_dir_path <- file.path(out, "simulations", key)
  x$batch_num <- key
  x
}
manifest <- expand.grid(scenario = scenarios, model = models, stringsAsFactors = FALSE)
manifest$key <- paste(manifest$scenario, manifest$model, sep = "_")
manifest$input <- file.path(input_dir, paste0("INPUT_", manifest$key, "_Delaware.json"))
configs <- lapply(seq_len(nrow(manifest)), function(i) make_config(manifest$scenario[i], manifest$model[i]))
comparison_config <- function(x) {
  x$disease_model$identity <- NULL
  x$output_dir_path <- x$batch_num <- NULL
  x
}
for (scenario in scenarios) {
  pair <- configs[manifest$scenario == scenario]
  stopifnot(identical(comparison_config(pair[[1]]), comparison_config(pair[[2]])))
}
# Include loaders, treatments, and output handling in the implementation fingerprint.
source_paths <- list.files(file.path(repo, "src"), pattern = "[.]py$", recursive = TRUE, full.names = TRUE)
data_md5 <- setNames(as.list(unname(tools::md5sum(unlist(base$data)))), names(base$data))
risk <- read.csv(base$data$high_risk_ratios, check.names = FALSE)
stopifnot(!anyDuplicated(risk$fips), setequal(risk$fips, pop$fips),
  setequal(names(risk)[-1], names(pop)[-1]))
risk <- risk[match(pop$fips, risk$fips), names(pop)]
risk_values <- as.matrix(risk[, -1]); population_values <- as.matrix(pop[, -1])
stopifnot(all(is.finite(risk_values)), all(risk_values >= 0 & risk_values <= 1))
expected_high_risk <- population_values - round(population_values * (1-risk_values))
source_relative <- substring(source_paths, nchar(repo) + 2)
source_md5 <- setNames(as.list(unname(tools::md5sum(source_paths))), source_relative)
manifest$source_folder <- vapply(configs, function(x) x$output_dir_path, character(1))
manifest$source_key <- manifest$key
manifest$reused <- FALSE
if (nzchar(arg("--reuse-dir","")))
  stop("External batch reuse is disabled for self-contained runs. Use --resume for local completed batches.")
# Relative manifest paths make saved results relocatable with the experiment.
relative_to_run <- function(path) {
  if (!startsWith(path,paste0(out,"/"))) stop("Output dependency outside experiment: ",path)
  substring(path,nchar(out)+2)
}
saved_manifest <- manifest
saved_manifest$input <- vapply(manifest$input,relative_to_run,character(1))
saved_manifest$source_folder <- vapply(manifest$source_folder,relative_to_run,character(1))
settings <- list(format_version = 2L, days = days, realizations = realizations, model_source_md5 = source_md5,
  input_data_md5 = data_md5, risk_ratio_scope = "county_by_age",
  low_exposed = low_seed, high_exposed = high_seed, vaccine_doses = as.list(vaccine_doses),
  vaccine_effectiveness = vaccine_effectiveness, antiviral_doses = as.list(antiviral_doses),
  vaccine_release_days = vaccine_release_days, vaccine_daily_doses = vaccine_daily_doses,
  vaccine_lag_days = vaccine_lag_days, state_population = state_population, self_contained = TRUE, manifest = saved_manifest)
settings_path <- file.path(out, "comparison_settings.json")
if (!plots_only) {
  if (resume && file.exists(settings_path)) {
    old <- read_json(settings_path, simplifyVector = TRUE)
    for (key in c("format_version", "days", "realizations", "low_exposed", "high_exposed", "vaccine_doses", "vaccine_effectiveness", "antiviral_doses"))
      if (!isTRUE(all.equal(unname(unlist(old[[key]])), unname(unlist(settings[[key]]))))) stop("Resume settings differ: ", key)
    if (!identical(as.list(old$input_data_md5), data_md5)) stop("Input data changed; choose a new --output-dir.")
    if (!identical(as.list(old$model_source_md5), source_md5))
      stop("Model source changed; choose a new --output-dir rather than mixing implementations.")
  }
  for (i in seq_along(configs)) {
    x <- configs[[i]]
    folder <- x$output_dir_path
    nonempty <- dir.exists(folder) && length(list.files(folder, all.files = TRUE, no.. = TRUE)) > 0
    if (nonempty) {
      if (!resume || !file.exists(file.path(folder, "_SUCCESS")))
        stop("Existing or incomplete output: ", folder, ". Choose a new --output-dir; use --resume for completed batches.")
      saved <- read_json(manifest$input[i], simplifyVector = FALSE)
      proposed <- fromJSON(toJSON(x, auto_unbox = TRUE, null = "null"), simplifyVector = FALSE)
      canonical_resume <- function(config) {
        # Worker count and absolute directory names do not change the science.
        # Data/source checksums above still have to match the saved run.
        config$execution <- config$output_dir_path <- NULL
        config$data <- lapply(config$data,basename)
        config
      }
      if (!identical(canonical_resume(saved), canonical_resume(proposed)))
        stop("Resume input differs: ", manifest$key[i])
      write_json(x,manifest$input[i],auto_unbox=TRUE,pretty=TRUE,null="null")
    } else write_json(x, manifest$input[i], auto_unbox = TRUE, pretty = TRUE, null = "null")
  }
  write_json(settings, settings_path, auto_unbox = TRUE, pretty = TRUE)
  for (i in seq_along(source_paths)) {
    dest <- file.path(out, "source_snapshot", source_relative[i])
    dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
    if (!file.exists(dest)) file.copy(source_paths[i], dest)
    if (unname(tools::md5sum(dest)) != source_md5[[i]]) stop("Source snapshot differs: ", dest)
  }
  data_snapshot <- file.path(out, "data_snapshot")
  dir.create(data_snapshot, showWarnings = FALSE)
  for (path in unlist(base$data)) {
    dest <- file.path(data_snapshot, basename(path))
    if (!file.exists(dest)) file.copy(path, dest)
    if (unname(tools::md5sum(dest)) != unname(tools::md5sum(path))) stop("Data snapshot differs: ", dest)
  }
  message("Prepared ", nrow(manifest), " matched scenario/model inputs in ", input_dir)
}
if (prepare_only) quit(save = "no", status = 0)
if (!plots_only) {
  python <- arg("--python", "")
  # Share a writable font cache across all simulator subprocesses.
  cache <- file.path(out, "matplotlib_cache")
  dir.create(cache, showWarnings = FALSE)
  Sys.setenv(MPLCONFIGDIR = cache)
  for (i in seq_along(configs)) {
    x <- configs[[i]]
    if (manifest$reused[i]) { message("Reusing verified batch for ", manifest$key[i]); next }
    if (resume && file.exists(file.path(x$output_dir_path, "_SUCCESS"))) next
    message("Running ", manifest$key[i], ": ", realizations, " realizations, up to ", days, " days")
    dir.create(x$output_dir_path, recursive = TRUE, showWarnings = FALSE)
    sim_args <- c(shQuote(file.path(repo, "src/simulator.py")), "-l", "WARNING", "-d", days,
                  "-i", shQuote(manifest$input[i]))
    log <- file.path(out, paste0(manifest$key[i], ".log"))
    status <- if (nzchar(python)) system2(python, sim_args, stdout = log, stderr = log) else
      system2("poetry", c("-C", shQuote(repo), "run", "python", sim_args), stdout = log, stderr = log)
    if (status != 0) stop("Simulation failed; see ", log)
    file.create(file.path(x$output_dir_path, "_SUCCESS"))
  }
}
# Saved settings govern replotting; CLI defaults must not reinterpret saved output.
settings <- read_json(settings_path, simplifyVector = TRUE)
if (!identical(settings$format_version, 2L)) stop("Expected four-panel output (format_version 2)")
days <- settings$days
vaccine_effectiveness <- settings$vaccine_effectiveness %||10b% 0.95
realizations <- settings$realizations
manifest <- settings$manifest
resolve_run_path <- function(path) if (grepl("^/|^[A-Za-z]:",path)) path else file.path(out,path)
manifest$input <- vapply(manifest$input,resolve_run_path,character(1))
manifest$source_folder <- vapply(manifest$source_folder,resolve_run_path,character(1))
if (isTRUE(settings$self_contained)) {
  for (path in c(manifest$input,manifest$source_folder))
    if (!startsWith(normalizePath(path,mustWork=TRUE),paste0(out,"/")))
      stop("Experiment references an external output: ",path)
}
scenarios <- unique(manifest$scenario)
vaccine_scenarios <- names(settings$vaccine_doses) %||10b% names(settings$vaccine_daily_doses)
vaccine_totals <- unlist(settings$vaccine_doses)
vaccine_comparison <- paste0(format(vaccine_totals[1]/1000, trim=TRUE), "K vs ",
  format(vaccine_totals[2]/1000000, trim=TRUE), "M doses")
antiviral_scenarios <- scenarios[startsWith(scenarios, "antiviral")]
antiviral_totals <- if (!is.null(settings$antiviral_doses)) unlist(settings$antiviral_doses) else
  setNames(vapply(antiviral_scenarios, function(scenario) {
    input <- read_json(manifest$input[match(scenario, manifest$scenario)], simplifyVector=TRUE)
    sum(as.integer(input$antiviral_model$parameters$antiviral_stockpile$amount))
  }, numeric(1)), antiviral_scenarios)
antiviral_comparison <- paste0(antiviral_totals[1]/1000, "K vs ", antiviral_totals[2]/1000, "K")
read_model <- function(i) {
  key <- manifest$source_key[i]
  folder <- manifest$source_folder[i]
  x <- read.csv(file.path(folder, paste0("network_batch-", key, ".csv")))
  if (!"T" %in% names(x)) x$T <- 0
  compartments <- c("S", "E", "I", "T", "R")
  stopifnot(!anyDuplicated(x[c("sim_id", "day")]),
    setequal(x$sim_id, seq_len(realizations) - 1L), all(x$day >= 0 & x$day <= days),
    all(is.finite(as.matrix(x[compartments]))), all(as.matrix(x[compartments]) >= -1e-8))
  check <- x %>% group_by(sim_id) %>% summarise(
    complete = identical(as.integer(day), seq.int(0L, max(day))),
    conserved = max(abs((S + E + I + T + R) - settings$state_population)) < 1e-5,
    seed_valid = first(E) == if (manifest$scenario[i] == "low") settings$low_exposed else settings$high_exposed,
    valid_stop = last(day) == days || last(E + I + T) <= .99 + 1e-8,
    .groups = "drop")
  stopifnot(nrow(check) == realizations, all(check$complete), all(check$conserved), all(check$seed_valid), all(check$valid_stop))
  x <- x %>% group_by(sim_id) %>% mutate(last_recorded_day = max(day)) %>%
    complete(day = 0:days) %>% fill(all_of(c(compartments, "last_recorded_day")), .direction = "down") %>%
    ungroup() %>% mutate(scenario = manifest$scenario[i], model = manifest$model[i],
                        total_infectious = I + T)
  # Audit implemented interventions from subgroup output, not just requested input.
  node_paths <- list.files(folder, pattern = paste0("^node_.*_batch-", key, "[.]csv$"), full.names = TRUE)
  stopifnot(length(node_paths) == realizations)
  audit <- bind_rows(lapply(node_paths, function(path) {
    z <- read.csv(path)
    if (identical(settings$risk_ratio_scope, "county_by_age")) {
      initial <- z[z$day == 0, ]
      county_index <- match(initial$fips_id, pop$fips)
      stopifnot(nrow(initial) == nrow(pop), !anyNA(county_index))
      for (age in seq_len(ncol(expected_high_risk))-1L) {
        high_cols <- grep(paste0("^[SEITR]_H_[UV]_age", age, "$"), names(z), value = TRUE)
        stopifnot(length(high_cols) > 0,
          all(abs(rowSums(initial[high_cols]) - expected_high_risk[county_index, age+1L]) < 1e-5))
      }
    }
    vaccinated_cols <- grep("^[SEITR]_[LH]_V_age", names(z), value = TRUE)
    data.frame(sim_id = z$sim_id, day = z$day,
      vaccinated = rowSums(z[vaccinated_cols]), I = z$I, T = if ("T" %in% names(z)) z$T else 0)
  })) %>% group_by(sim_id, day) %>% summarise(vaccinated = sum(vaccinated), I = sum(I), T = sum(T), .groups = "drop")
  stopifnot(all(audit$T[audit$day < 30] == 0))
  input <- read_json(manifest$input[i], simplifyVector = TRUE)
  expected_vax <- rep(0, nrow(audit))
  if (manifest$scenario[i] %in% vaccine_scenarios) {
    releases <- input$vaccine_model$parameters$vaccine_stockpile
    effective_days <- as.integer(releases$day) + input$vaccine_model$parameters$vaccine_eff_lag_days
    expected_vax <- vapply(audit$day, function(day)
      sum(as.integer(releases$amount)[effective_days <= day]), numeric(1))
  }
  stopifnot(all(audit$vaccinated >= -1e-5), all(audit$vaccinated <= expected_vax + 1e-5))
  if (manifest$scenario[i] != "vax1m")
    stopifnot(all(abs(audit$vaccinated - expected_vax) < 1e-5))
  monotone <- audit %>% arrange(sim_id, day) %>% group_by(sim_id) %>%
    summarise(valid = all(diff(vaccinated) >= -1e-5), .groups = "drop")
  stopifnot(all(monotone$valid))
  audit$available_vaccine_doses <- expected_vax
  audit$unadministered_vaccine_doses <- pmax(0, expected_vax - audit$vaccinated)
  if (manifest$scenario[i] %in% antiviral_scenarios && days >= 30)
    stopifnot(sum(audit$T[audit$day == 30]) > 0)
  audit$scenario <- manifest$scenario[i]
  audit$model <- manifest$model[i]
  list(states = x, audit = audit)
}
if (vaccine_panel_only) {
  states <- read.csv(file.path(out, "statewide_trajectories.csv"))
} else {
  results <- lapply(seq_len(nrow(manifest)), read_model)
  states <- bind_rows(lapply(results, `[[`, "states"))
  write.csv(bind_rows(lapply(results, `[[`, "audit")), file.path(out, "intervention_audit.csv"), row.names = FALSE)
  write.csv(states, file.path(out, "statewide_trajectories.csv"), row.names = FALSE)
  plot_10b_baseline(states, settings, out, figure_dir)
  diagnose_10b_reproduction(settings, repo, out)
}
summary <- states %>% group_by(scenario, model, day) %>% summarise(
  mean = mean(I), median = median(I), lower = quantile(I, .025), upper = quantile(I, .975),
  mean_treated = mean(T), mean_total_infectious = mean(total_infectious), n = n(), .groups = "drop")
stopifnot(all(summary$n == realizations))
write.csv(summary, file.path(out, "trajectory_summary.csv"), row.names = FALSE)
metrics <- states %>% group_by(scenario, model, sim_id) %>% summarise(
  peak_I = max(I), peak_I_day = day[which.max(I)],
  infectious_person_days = sum(I[day > 0 & day <= last_recorded_day]),
  total_infectious_person_days = sum(total_infectious[day > 0 & day <= last_recorded_day]),
  peak_T = max(T), I_day30 = I[day == min(30L, days)], T_day30 = T[day == min(30L, days)],
  last_recorded_day = first(last_recorded_day), final_recovered = last(R),
  ever_exposed = settings$state_population - last(S),
  remaining_exposed_infectious = last(E + I + T), .groups = "drop")
write.csv(metrics, file.path(out, "realization_metrics.csv"), row.names = FALSE)
metric_summary <- metrics %>% group_by(scenario, model) %>% summarise(
  peak_I_median = median(peak_I), peak_I_lower = quantile(peak_I, .025), peak_I_upper = quantile(peak_I, .975),
  final_recovered_median = median(final_recovered),
  last_recorded_day_median = median(last_recorded_day), .groups = "drop")
write.csv(metric_summary, file.path(out, "comparison_metrics.csv"), row.names = FALSE)
# Reuse the exact same high-exposure baseline in B, C, D; no duplicate simulation batches.
panels <- c("A  Initial exposures", paste0("B  Vaccination: ", 100*vaccine_effectiveness, "% effective; ", vaccine_comparison), "C  School closure: days 30-50", paste0("D  Antiviral: ", antiviral_comparison, " on day 30"))
panel_map <- data.frame(panel = rep(panels, c(2, 3, 2, 3)),
  scenario = c("low", "high", "high", vaccine_scenarios, "high", "closure", "high", antiviral_scenarios))
plot_states <- inner_join(states, panel_map, by = "scenario", relationship = "many-to-many")
plot_summary <- inner_join(summary, panel_map, by = "scenario", relationship = "many-to-many")
plot_states$panel <- factor(plot_states$panel, levels = panels)
plot_summary$panel <- factor(plot_summary$panel, levels = panels)
scenario_labels <- c(low = paste0("Initial Exposed: ", format(settings$low_exposed, big.mark = ",")),
  high = paste0("Initial Exposed / baseline: ", format(settings$high_exposed, big.mark = ",")),
  setNames(paste0("Vaccine: ", format(vaccine_totals, big.mark=",", scientific=FALSE, trim=TRUE), " doses"), vaccine_scenarios),
  closure = "Closure: ages 5-17 -90%, adults -50%",
  setNames(paste0("Antiviral: ", format(antiviral_totals, big.mark=",", scientific=FALSE, trim=TRUE), " courses"), antiviral_scenarios))
# Keep 10a's intervention color families, with lighter tones for dose comparisons.
# Use gray for the common baseline and charcoal for the lower initial exposure.
palette <- c(low = "#222222", high = "#777777", setNames(c("#596246", "#9CA58D"), vaccine_scenarios), closure = "#bd6b4f", setNames(c("#F7D18C", "#f2ad2e"), antiviral_scenarios))
write.csv(data.frame(scenario = names(palette), color = unname(palette)),
  file.path(out, "figure_colors.csv"), row.names = FALSE)
markers <- data.frame(panel = factor(c(panels[2], panels[2], panels[3], panels[3], panels[4]), levels = panels),
  day = c(range(settings$vaccine_release_days), 30, 50, 30))
plot_example <- function(log_scale = TRUE, panel_selection = NULL) {
  text_pt <- 13
  text_mm <- text_pt / ggplot2::.pt
  selected_states <- if (is.null(panel_selection)) plot_states else filter(plot_states, panel == panel_selection)
  selected_summary <- if (is.null(panel_selection)) plot_summary else filter(plot_summary, panel == panel_selection)
  selected_markers <- if (is.null(panel_selection)) markers else filter(markers, panel == panel_selection)
  panel_names <- if (is.null(panel_selection)) panels else panel_selection
  make_panel <- function(panel_name,index) {
    panel_states <- filter(selected_states,panel==panel_name)
    panel_summary <- filter(selected_summary,panel==panel_name)
    panel_markers <- filter(selected_markers,panel==panel_name)
    bottom_row <- length(panel_names)==1 || index>2
    left_column <- length(panel_names)==1 || index %% 2 == 1
    p <- ggplot() +
    geom_vline(data = panel_markers, aes(xintercept = day), colour = "grey35", linetype = "dotted", linewidth = 1.1) +
    geom_ribbon(data = panel_summary, aes(day, ymin = lower, ymax = upper, fill = scenario,
      group = interaction(scenario, model)), alpha = .15, colour = NA, show.legend = FALSE) +
    geom_line(data = panel_states, aes(day, I, colour = scenario, linetype = model,
      group = interaction(scenario, model, sim_id)), linewidth = .2, alpha = .07, show.legend = FALSE) +
    geom_line(data = panel_summary, aes(day, median, colour = scenario, linetype = model,
      group = interaction(scenario, model)), linewidth = .9) +
    scale_x_continuous(limits = c(0, days), breaks = pretty(c(0, days), n = 5), expand = expansion(mult = c(.01, .02))) +
    scale_color_manual(values = palette, breaks = scenarios, labels = scenario_labels[scenarios]) +
    scale_fill_manual(values = palette) +
    scale_linetype_manual(values = c(deterministic = "solid", stochastic = "22"),
      breaks = models, labels = c("Deterministic SEI(T)R", "Stochastic SEI(T)R")) +
    labs(title = "Delaware: statewide infectious population",
      subtitle = paste0("R0 = 1.2  |  exposed 1 day  |  infectious 7 days  |  ", realizations, " realizations per model and scenario"),
      x = "Simulation day", y = if (log_scale) "Infectious people (I; log1p scale)" else "Infectious people (I)",
      colour = NULL, linetype = NULL,
      caption = paste0("Thin lines: individual runs; bold: median; shading: central 95% of runs. Binomial travel in both models.\n",
        "B-D use 10,000 Initial Exposed. B: ", vaccine_comparison, " released days 30-50 (dotted lines); both ", 100*vaccine_effectiveness, "% effective, with a 14-day protection lag. C: ages 0-4 unchanged; adults = 18+.\n",
        "D: treated infectious people move from I to T (not plotted), with 50% lower infectiousness and 5-day recovery from treatment.\n",
        "After network E + I (+ T) <= 0.99, terminal states are held through day ", days, "; no waning immunity; county-specific age risk fractions.")) +
    theme_bw(base_size = text_pt) + theme(legend.position = "bottom", legend.box = "vertical",
      panel.grid.minor = element_blank(), strip.text = element_text(hjust = 0, face = "bold", size = text_pt),
      panel.background = element_rect(fill = "white", colour = NA),
      plot.background = element_rect(fill = "white", colour = NA),
      axis.text = element_text(size = text_pt, color = "black"), axis.title = element_text(size = 16),
      plot.title = element_text(size = 17, face = "bold", hjust = .5, margin=margin(b=6)),
      plot.margin = margin(t=14,r=12,b=8,l=10),
      axis.text.x = if (bottom_row) element_text(size=text_pt,color="black") else element_blank(),
      axis.ticks.x = if (bottom_row) element_line() else element_blank(),
      plot.caption = element_text(hjust = 0, size = text_pt), legend.text = element_text(size = text_pt)) +
    guides(colour = guide_legend(ncol = 2, order = 1, override.aes = list(linewidth = 1)),
           linetype = guide_legend(nrow = 1, order = 2))
  if (log_scale) p <- p + scale_y_continuous(transform = "log1p", limits = c(0, NA),
    breaks = c(0, 1, 10, 100, 1000, 10000, 100000), labels = compact_axis_label) else
    p <- p + scale_y_continuous(limits = c(0, NA), labels = compact_axis_label)
    p + labs(title=sub("^[A-D]  ","",panel_name),subtitle=NULL,caption=NULL,
      x=if(bottom_row) "Simulation day" else NULL,
      y=if(left_column) if(log_scale) "Infectious people (I; log1p)" else "Infectious people (I)" else NULL) +
      theme(legend.position="none")
  }
  panel_plots <- lapply(seq_along(panel_names),function(i) make_panel(panel_names[i],i))
  p <- cowplot::plot_grid(plotlist=panel_plots,ncol=if(length(panel_names)==1) 1 else 2,
    align="v",axis="lr",labels=substring(panel_names,1,1),label_size=24,label_fontface="bold",
    label_x=.01,label_y=.99,hjust=0,vjust=1)
  keys <- data.frame(scenario = scenarios, x = (seq_along(scenarios) - .5) / length(scenarios),
    label = c(paste0("Initial Exposed\n", format(settings$low_exposed, big.mark = ",")),
      paste0("Initial Exposed\n", format(settings$high_exposed, big.mark = ","), " / baseline"),
      paste0("Vaccine\n", format(vaccine_totals, big.mark=",", scientific=FALSE, trim=TRUE), " doses"), "School closure\nDays 30-50",
      paste0("Antiviral\n", format(antiviral_totals, big.mark=",", scientific=FALSE, trim=TRUE), " courses")))
  keys <- keys[keys$scenario %in% unique(selected_states$scenario), ]
  keys$x <- (seq_len(nrow(keys)) - .5) / nrow(keys)
  color_row <- ggplot(keys) +
    geom_segment(aes(x = x-.035, xend = x+.035, y = .88, yend = .88, color = scenario), linewidth = 1.4) +
    geom_text(aes(x, .74, label = label), size = text_mm, vjust = 1, lineheight = 1.1) +
    scale_color_manual(values = palette, guide = "none") +
    coord_cartesian(xlim = c(0,1), ylim = c(0,1), expand = FALSE) + theme_void() +
    theme(plot.margin = margin(0, 12, 0, 12))
  method_row <- ggplot(data.frame(x = c(.34,.66), model = models,
    label = c("Deterministic SEI(T)R", "Stochastic SEI(T)R"))) +
    geom_segment(aes(x = x-.12, xend = x-.07, y = .5, yend = .5, linetype = model), linewidth = 1.2) +
    geom_text(aes(x = x-.05, y = .5, label = label), hjust = 0, size = 17 / ggplot2::.pt) +
    scale_linetype_manual(values = c(deterministic = "solid", stochastic = "22"), guide = "none") +
    coord_cartesian(xlim = c(0,1), ylim = c(0,1), expand = FALSE) + theme_void()
  cowplot::plot_grid(p,
    color_row, method_row, ncol = 1, rel_heights = c(1,.075,.055))
}
if (!vaccine_panel_only) for (kind in c("log1p", "linear")) {
  p <- plot_example(kind == "log1p")
  for (ext in c("png", "pdf")) ggsave(file.path(figure_dir, paste0("statewide_2x2_", kind, ".", ext)),
    p, width = 15, height = 11.5, dpi = 300, bg = "white")
}
for (ext in c("png", "pdf")) ggsave(file.path(figure_dir, paste0("vaccine_panel.", ext)),
  plot_example(FALSE, panels[2]), width = 13, height = 8, dpi = 300, bg = "white")
# Keep interpretive text in a companion PDF, not in the manuscript figure body.
write_example_notes <- function(path) {
  grDevices::pdf(path, width=8.5, height=11, family="Helvetica")
  on.exit(grDevices::dev.off())
  grid::grid.newpage()
  cursor <- 10.35
  wrap_text <- function(text, size, face) {
    words <- strsplit(text, " +")[[1]]; lines <- character(); line <- ""
    for (word in words) {
      candidate <- if (nzchar(line)) paste(line, word) else word
      width <- grid::convertWidth(grid::grobWidth(grid::textGrob(candidate,
        gp=grid::gpar(fontsize=size, fontface=face))), "inches", valueOnly=TRUE)
      if (width > 7.2 && nzchar(line)) { lines <- c(lines,line); line <- word }
      else line <- candidate
    }
    paste(c(lines,line), collapse="\n")
  }
  paragraph <- function(text, size=11, face="plain", gap=.15) {
    text <- wrap_text(text,size,face)
    grob <- grid::textGrob(text, x=grid::unit(.65,"inches"),
      y=grid::unit(cursor,"inches"), just=c("left","top"),
      gp=grid::gpar(fontsize=size,fontface=face,lineheight=1.25,col="#222222"))
    height <- grid::convertHeight(grid::grobHeight(grob),"inches",valueOnly=TRUE)
    if (cursor-height < .65) {
      grid::grid.newpage(); cursor <<- 10.35
      grob$y <- grid::unit(cursor,"inches")
    }
    grid::grid.draw(grob)
    cursor <<- cursor-height-gap
  }
  paragraph("Delaware: statewide infectious population",16,"bold",.12)
  paragraph(paste0("R0 = 1.2; exposed for 1 day; untreated infectious for 7 days. ",
    realizations," realizations per model and scenario, over ",days," simulation days."))
  paragraph("Reading the figures",12,"bold",.08)
  paragraph("Thin lines show individual runs, bold lines the median, and shading the central 95% of runs. Solid lines denote deterministic SEI(T)R and dashed lines stochastic SEI(T)R. Binomial travel is active in both models. The plotted compartment is I; treated infectious people (T) are not included in the plotted count. The linear and log1p figures show the same saved simulations.")
  paragraph("A. Initial exposures",12,"bold",.08)
  paragraph(paste0(format(settings$low_exposed,big.mark=",")," versus ",
    format(settings$high_exposed,big.mark=",")," initially exposed people. Panels B-D share the ",
    format(settings$high_exposed,big.mark=","),"-exposure baseline."))
  paragraph("B. Vaccination",12,"bold",.08)
  paragraph(paste0(vaccine_comparison," are released over simulation days 30-50, inclusive, at ",
    100*vaccine_effectiveness,"% effectiveness. Dotted lines mark the first and last dose-release days (30 and 50), not the protection window. With the 14-day lag, protection begins over days 44-64. Only eligible susceptible people are vaccinated, so released supply can exceed the number vaccinated. Vaccine effectiveness reduces susceptibility to infection."))
  paragraph("C. School closure",12,"bold",.08)
  paragraph("Dotted lines mark closure days 30 and 50. Closure is active on days 30-50 inclusive; normal contacts resume on day 51. Contacts are reduced by 90% for ages 5-17 and by 50% for adults (18+); ages 0-4 are unchanged.")
  paragraph("D. Antivirals",12,"bold",.08)
  paragraph(paste0(antiviral_comparison," courses are released on day 30, indicated by the dotted line. Stockpile allocation transfers eligible infectious people from I to T. Treated infection has 50% lower infectiousness and a mean 5-day recovery time after treatment; untreated infection has a mean 7-day recovery time."))
  paragraph("Shared inputs and time convention",12,"bold",.08)
  paragraph(paste0("All scenarios use Delaware county-specific age risk fractions, matched to population data by county FIPS. Day 0 is the initial state; day labels are elapsed simulation days. There is no waning immunity. After network E + I (+ T) falls to 0.99 or below, terminal states are held through day ",days," for plotting."))
}
write_example_notes(file.path(figure_dir,"statewide_2x2_notes.pdf"))
input_plot_status <- system2("Rscript", c("--vanilla", shQuote(file.path(repo, "scripts/10c_manuscript_illustrative_inputs.R")),
  shQuote(paste0("--output-dir=", file.path(out, "input_figure"))),
  if (nzchar(shape_path)) shQuote(paste0("--county-shapefile=",shape_path)) else character(),
  shQuote(paste0("--data-dir=",data_snapshot)),
  shQuote(paste0("--figure-dir=",figure_dir))))
if (input_plot_status != 0) stop("Input figure export failed")
write_10b_example_readme(out)
message("Saved manuscript figures in ",figure_dir,"; simulation data and comparison tables in ",out)
print(metric_summary, width = Inf)
