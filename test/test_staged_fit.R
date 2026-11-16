# Run: Rscript --vanilla test/test_staged_fit.R
# Exercise the actual 5c functions without starting simulations.
suppressPackageStartupMessages({library(dplyr); library(purrr); library(tibble)})
source("scripts/5c_Rm_search_helpers.R")
`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x
code <- as.list(parse("scripts/5c_Rm_search.R"))
load_function <- function(name) {
  expression <- Filter(function(x) is.call(x) && identical(x[[1]], as.name("<-")) && identical(x[[2]], as.name(name)), code)
  stopifnot(length(expression)==1L)
  eval(expression[[1]], .GlobalEnv)
}
for (name in c("exposure_allocation_key", "scale_initial_exposed", "rank_exposure_candidates", "next_exposure_total", "next_adaptive_exposure",
  "candidate_context", "make_staged_context", "select_best_r0", "search_state_staged", "read_sweep_table",
  "write_csv_preserving_existing", "with_sweep_file_lock")) load_function(name)
rows <- Map(function(i,n) list(county=as.character(i), age_group="2", infected=as.character(n)), 1:4, c(1,24,100,600))
for (total in c(1,10,483,725,1450)) {
  scaled <- scale_initial_exposed(rows, total)
  stopifnot(sum(vapply(scaled, function(row) as.numeric(row$infected), numeric(1)))==total,
    all(vapply(scaled, function(row) as.numeric(row$infected)>0, logical(1))),
    identical(vapply(rows, `[[`, character(1), "infected"), c("1","24","100","600")))
}
stopifnot(identical(exposure_allocation_key(list(list(county="11001",age_group=0,infected=29.0))),
  exposure_allocation_key(list(list(county="11001",age_group="0",infected="29")))))
peak_height_tolerance <- .15
ranking <- tibble(initial_exposed_total=c(1,2,3), predicted_peak_height=c(30,95,105), observed_peak_height=100,
  peak_lag_weeks=c(0,1,0), mean_wis=c(1,1,5))
stopifnot(rank_exposure_candidates(ranking)$initial_exposed_total[[1]]==3)
for (peak in c(85,115)) stopifnot(rank_exposure_candidates(mutate(ranking[1,], predicted_peak_height=peak))$height_ok)
prior_tie <- tibble(initial_exposed_total=c(74,147), original_initial_exposed_total=147,
  predicted_peak_height=c(210,211), observed_peak_height=211, peak_lag_weeks=0, mean_wis=c(22,34))
stopifnot(rank_exposure_candidates(prior_tie, prefer_original=TRUE)$initial_exposed_total[[1]] == 147,
  rank_exposure_candidates(prior_tie)$initial_exposed_total[[1]] == 74,
  rank_exposure_candidates(mutate(prior_tie, peak_lag_weeks=c(0,1)), prefer_original=TRUE)$initial_exposed_total[[1]] == 74,
  rank_exposure_candidates(mutate(prior_tie, predicted_peak_height=c(210,300)), prefer_original=TRUE)$initial_exposed_total[[1]] == 74)
records <- tibble(initial_exposed_total=c(36,287,363,483,725), sample_count=100)
stopifnot(next_exposure_total(records,tibble(initial_exposed_total=363,peak_lag_weeks=1,sample_count=100))==483,
  next_exposure_total(records,tibble(initial_exposed_total=483,peak_lag_weeks=-1,sample_count=100))==363,
  next_exposure_total(records,tibble(initial_exposed_total=36,peak_lag_weeks=2,sample_count=100))==102,
  is.null(next_exposure_total(records,tibble(initial_exposed_total=363,peak_lag_weeks=0,sample_count=100))))

temporary <- tempfile("staged-native-")
dir.create(temporary)
fit_initial_exposed <- TRUE
table_path <- file.path(temporary,"scores.csv")
readr::write_csv(tibble(geo_region=c("A","A","B"), disease_R0=c(1.2,1.5,2)),table_path)
write_csv_preserving_existing(tibble(geo_region="A",disease_R0=1.3),table_path)
updated <- readr::read_csv(table_path,show_col_types=FALSE)
stopifnot(nrow(updated)==2L,identical(updated$disease_R0[updated$geo_region=="A"],1.3),"B" %in% updated$geo_region)
fit_initial_exposed <- FALSE
repo_root <- normalizePath(".")
pipeline_root <- normalizePath(temporary)
original_seed <- file.path(temporary,"seed.json")
scenario <- file.path(temporary,"scenario.json")
data <- file.path(temporary,"population.csv")
target <- file.path(temporary,"observed.csv")
writeLines("1000",data); writeLines("10",target)
seed <- list(initial_exposed=list(list(county="11001",age_group="0",infected="10")),
  disease_model=list(parameters=list(R0="2.2",IS_to_R_days="7")), data=list(population=data),
  travel_model=list(), non_pharma_interventions=list(), antiviral_model=list(), vaccine_model=list())
jsonlite::write_json(seed,original_seed,auto_unbox=TRUE)
base <- seed; base$initial_exposed[[1]]$infected <- "5"
jsonlite::write_json(base,scenario,auto_unbox=TRUE)
seed_input_file <- function(state) original_seed
base_input_file <- function(state) scenario
absolutize_data_paths <- function(config, source) config
resolve_validation_file <- function(metadata) target
scenario_label <- "ALL_INTERVENTIONS"; simulation_days <- 200L
realization_range <- c(7L,9L); screening_realizations <- 2L
exposure_multipliers <- c(.5,2/3,1); base_r0 <- 1.2; refine_step <- .025
staged_version <- "staged_r0_exposures_v4"
none_template_file <- vaccine_template_file <- antiviral_template_file <- npi_template_file <- all_interventions_template_file <- target
first <- make_staged_context("District-of-Columbia")
base$initial_exposed[[1]]$infected <- "2"; base$disease_model$parameters$R0 <- "1.825"
jsonlite::write_json(base,scenario,auto_unbox=TRUE)
stopifnot(first$original_total==10, identical(first$run_signature,make_staged_context("District-of-Columbia")$run_signature))
base$disease_model$parameters$IS_to_R_days <- "8"
jsonlite::write_json(base,scenario,auto_unbox=TRUE)
changed <- make_staged_context("District-of-Columbia")
stopifnot(!identical(first$run_signature,changed$run_signature))
writeLines("2000",data)
stopifnot(!identical(changed$run_signature,make_staged_context("District-of-Columbia")$run_signature))

# Bracketing, integer termination, and refinement toward the original E0.
probe <- function(E,lag) tibble(initial_exposed_total=E,peak_lag_weeks=lag)
stopifnot(next_adaptive_exposure(probe(1000,-3),1000,31,2000)==500,
  next_adaptive_exposure(probe(c(125,250),c(1,-1)),1000,31,2000)==177,
  next_adaptive_exposure(probe(c(125,250),c(0,-1)),1000,31,2000)==177,
  is.null(next_adaptive_exposure(probe(1000,0),1000,31,2000)),
  is.null(next_adaptive_exposure(probe(31,-1),1000,31,2000)),
  is.null(next_adaptive_exposure(probe(c(125,126),c(1,-1)),1000,31,2000)))

# A height-focused Rm refinement worsens timing. The final selection must retain
# its earlier, height-eligible Rm point, including when screening uses fewer runs.
active_staged_context <- NULL
winning_staged_contexts <- new.env(parent=emptyenv())
make_staged_context <- function(state) list(state=state, original_rows=list(list(county="11001",age_group="0",infected="1000")),
  original_total=1000, run_signature="test", settings=list(screening_realizations=25))
realization_range <- c(0L,99L)
exposure_multipliers <- c(1/32,2)
candidate_input_dir <- file.path(temporary,"inputs"); sim_output_dir <- file.path(temporary,"simulations"); sweep_root <- temporary
initial_step <- .4; min_step <- .05
r0_selection_metric <- "peak_height"; r0_search_metrics <- "peak_height"
calls <- list()
evaluate_candidate <- function(state,r0) {
  ctx <- candidate_context(state)
  total <- sum(vapply(ctx$rows,function(row) as.numeric(row$infected),numeric(1)))
  n <- diff(ctx$realization_range)+1L
  calls[[length(calls)+1L]] <<- list(total=total,n=n,R0=r0)
  summary <- tibble(geo_region=state,disease_R0=r0,predicted_median_total=100,observed_total=100,
    predicted_peak_height=if (r0==2) 95 else if (total==1000) 140 else 100,observed_peak_height=100,
    peak_lag_weeks=round(-log2(total/125))-as.integer(r0>2), mean_wis=total/100,sample_count=n)
  list(summary=summary,scores=tibble(),predictions=tibble(),samples=tibble(),observed=tibble())
}
r0_key <- function(value) as.character(value)
search_state <- function(state,search_base,search_step,search_min_step) {
  rows <- bind_rows(lapply(if (search_base==1.2) 2 else c(2,2.025),function(rm) evaluate_candidate(state,rm)$summary))
  best <- select_best_r0(rows)
  list(best=best,trace=mutate(rows,iteration=1L,step=.025,search_center=2,search_centers="R0=2"),
    scores=tibble(),predictions=tibble(),final_samples=tibble(),final_scores=tibble(),final_observed=tibble())
}
result <- search_state_staged("District-of-Columbia")
stopifnot(result$best$initial_exposed_total==162,result$best$disease_R0==2,result$best$peak_lag_weeks==0,
  result$best$sample_count==100, is.null(active_staged_context),
  candidate_context("District-of-Columbia")$rows[[1]]$infected=="162",
  sum(result$procedure$final_selected)==1L,
  result$procedure$disease_R0[result$procedure$final_selected]==2,
  sum(result$procedure$adaptive_search)==3L,
  identical(result$procedure$trial_id,seq_len(nrow(result$procedure))),
  file.exists(file.path(sweep_root,"staged","District-of-Columbia","searched_candidates.csv")))
searched <- readr::read_csv(file.path(sweep_root,"staged","District-of-Columbia","searched_candidates.csv"),show_col_types=FALSE)
stopifnot(all(searched$sample_count==100),any(searched$disease_R0==2.025),any(searched$initial_exposed_total==162))
# An unchanged incumbent must not stop exploration of a new coordinate pair.
# The second pair is a bridge; only the third pass finds an eligible zero lag.
make_staged_context <- function(state) list(state=state, original_rows=list(list(county="11001",age_group="0",infected="1000")),
  original_total=1000, run_signature="bridge", settings=list(screening_realizations=100))
evaluate_candidate <- function(state,r0) {
  ctx <- candidate_context(state); total <- as.numeric(ctx$rows[[1]]$infected)
  level <- round((r0-2)/.025)
  needed <- if (total>=125) 1 else if (total>=63) 2 else 2
  height <- if (total==1000 && level==0) 100 else if (level < needed) 70 else
    if (total<63 && level==needed) 95 else if (level==needed) 100 else 130
  summary <- tibble(geo_region=state,disease_R0=r0,predicted_median_total=100,observed_total=100,
    predicted_peak_height=height,observed_peak_height=100,peak_lag_weeks=round(-log2(total/125))-level,
    mean_wis=1,sample_count=100)
  list(summary=summary,scores=tibble(),predictions=tibble(),samples=tibble(),observed=tibble())
}
search_state <- function(state,search_base,search_step,search_min_step) {
  rms <- if (search_base==1.2) 2 else c(search_base,search_base+.025)
  rows <- bind_rows(lapply(rms,function(rm) evaluate_candidate(state,rm)$summary))
  list(best=select_best_r0(rows),trace=mutate(rows,iteration=1L,step=.025,search_center=search_base,search_centers="test"),
    scores=tibble(),predictions=tibble(),final_samples=tibble(),final_scores=tibble(),final_observed=tibble())
}
bridge <- search_state_staged("District-of-Columbia")
stopifnot(bridge$best$peak_lag_weeks==0, bridge$best$initial_exposed_total<63,
  any(bridge$procedure$stage=="Refine Rm at adaptive E0 3"))
unlink(temporary,recursive=TRUE)
cat("Adaptive E0 bracketing, original-E0 preference, full-candidate retention and confirmation passed.\n")
