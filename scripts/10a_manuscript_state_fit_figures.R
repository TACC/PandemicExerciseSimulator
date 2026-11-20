# Manuscript fit screening, using saved data only (never launches simulations).
# Run from the repository root or scripts/:
# Rscript scripts/10a_manuscript_state_fit_figures.R
# Optional: --sweep-dir=... --figure-dir=... --good-states=Delaware,...
#           --bad-states=California,... --acs-year-range=2020-2024
# Categories and thresholds are exploratory editorial aids, not validated tests.
suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(readr); library(purrr)
  library(ggplot2); library(tibble); library(jsonlite); library(cowplot); library(arrow); library(hubUtils)
})
filter <- dplyr::filter
select <- dplyr::select
# Compact count axes, preserving fractional K/M/B values without trailing zeros.
compact_axis_label <- function(x) {
  labels <- scales::label_number(scale_cut=scales::cut_short_scale())(x)
  labels <- sub("(\\.[0-9]*[1-9])0+([KMB]?)$", "\\1\\2", labels)
  sub("\\.0+([KMB]?)$", "\\1", labels)
}

args <- commandArgs(trailingOnly = TRUE)
arg <- function(key, default) {
  x <- args[startsWith(args, paste0(key, "="))]
  if (length(x)) substring(x[[1]], nchar(key) + 2) else default
}
repo <- normalizePath(if (basename(getwd()) == "scripts") ".." else ".")
source(file.path(repo,"scripts/manuscript_figure_legends.R"))
sweep <- normalizePath(arg("--sweep-dir", file.path(repo, "LS6_RmSweep_TEST/Rm_search/2025-10-04")), mustWork = TRUE)
figure_dir <- arg("--figure-dir", file.path(repo, "figures/manuscript"))
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)
out <- file.path(figure_dir,"state-fit")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
acs <- arg("--acs-year-range", "2020-2024")
read_table <- function(path) read_csv(path, show_col_types = FALSE, progress = FALSE)
best <- read_table(file.path(sweep, "Rm_search_best_by_state.csv"))
scores <- read_table(file.path(sweep, "Rm_search_scores_by_week.csv"))
stopifnot(!anyDuplicated(best$geo_region), length(unique(best$scenario_label)) == 1)
# Join on the selected R_m, not all candidates or a fresh optimization.
weekly <- inner_join(scores, best %>% select(geo_region, scenario_label, disease_R0),
                     by = c("geo_region", "scenario_label", "disease_R0")) %>%
  arrange(geo_region, date)
stopifnot(!anyDuplicated(weekly[c("geo_region", "date")]),
          setequal(weekly$geo_region, best$geo_region),
          all(is.finite(as.matrix(weekly[c("observed", "q0_5", "q0_025", "q0_975")]))))
plots <- sub("_final_r0_fit.png$", "", basename(list.files(file.path(sweep, "plots"),
                    pattern = "_final_r0_fit[.]png$", full.names = TRUE)))
stopifnot(setequal(plots, best$geo_region))

# Hub-style central prediction intervals summarize the distribution of runs,
# not the sampling precision of the mean. The hubverse tools use quantiles:
# https://hubverse-org.r-universe.dev/hubUtils/doc/manual.html
# https://hubverse-org.github.io/hubVis/reference/plot_step_ahead_model_output.html
# hubVis defaults to 50%, 80%, 95%; use its quantile definitions with our own
# ggplot/cowplot styling so manuscript typography and annotations are retained.
# Conditional on selected Rm: these runs do not sample parameter uncertainty.
`%||%` <- function(x,y) if (is.null(x) || !length(x)) y else x
source(file.path(repo,"scripts/5c_Rm_search_helpers.R"))
pipeline <- dirname(dirname(sweep))
master <- read_csv(file.path(pipeline,"metadata_master.csv"),show_col_types=FALSE,progress=FALSE,
  col_select=c(geo_region,disease_R0,metadata_sim_day_0,metadata_tags_json,scenario_hash,batch_num,
    realization_min,realization_max,sim_days,complete_realization_count))
master$tags <- map(master$metadata_tags_json,~jsonlite::fromJSON(.x,simplifyVector=FALSE))
master_all <- master
master <- master %>% filter(map_lgl(tags,~!is.null(.x$r0_search$candidate_R0)))
summarize_simulation_batch <- function(r) {
  network <- file.path(pipeline,"sim_data",r$scenario_hash,r$batch_num,"network.parquet")
  if (!file.exists(network)) stop("Individual simulations required for prediction intervals: ",network)
  daily <- as_tibble(arrow::read_parquet(network,col_select=c("sim_id","day","H")))
  stopifnot(!anyDuplicated(daily[c("sim_id","day")]),
    r$complete_realization_count==r$realization_max-r$realization_min+1)
  metadata <- list(metadata_tags=r$tags[[1]],cli_args=list(days=r$sim_days),
    realization_indices=list(min=r$realization_min,max=r$realization_max))
  samples <- r0_weekly_incident_samples(daily,metadata,r$sim_days)
  # Sum each complete realization before taking its median; summing weekly
  # medians would not give the median cumulative hospitalization burden.
  observed_dates <- weekly$date[weekly$geo_region==r$geo_region]
  cumulative <- samples %>% filter(date %in% observed_dates) %>%
    group_by(sim_id) %>% summarise(total=sum(generated),.groups="drop")
  sample_output <- samples %>% transmute(model_id="PES",location=r$geo_region,
    target_date=date,output_type="sample",output_type_id=as.character(sim_id),value=generated) %>%
    hubUtils::as_model_out_tbl()
  quantiles <- hubUtils::convert_output_type(sample_output,
    to=list(quantile=c(.025,.10,.25,.50,.75,.90,.975)))
  result <- as_tibble(quantiles) %>%
    transmute(date=target_date,quantile_name=paste0("q",output_type_id),value) %>%
    pivot_wider(names_from=quantile_name,values_from=value) %>%
    rename(pi95_lower=q0.025,pi80_lower=q0.1,pi50_lower=q0.25,
      fitted_median=q0.5,pi50_upper=q0.75,pi80_upper=q0.9,pi95_upper=q0.975) %>%
    left_join(samples %>% group_by(date) %>% summarise(
      fitted_mean=mean(generated),n_simulations=n(),.groups="drop"),by="date") %>%
    mutate(cumulative_median=median(cumulative$total),
      cumulative_pi95_lower=as.numeric(quantile(cumulative$total,.025)),
      cumulative_pi95_upper=as.numeric(quantile(cumulative$total,.975)),
      geo_region=r$geo_region,scenario_label=r$tags[[1]]$scenario_label,
      disease_R0=r$disease_R0,batch_num=r$batch_num,network_source=network)
  result
}
projections <- map_dfr(seq_len(nrow(best)),function(i) {
  b <- best[i,]
  candidates <- master %>% filter(geo_region==b$geo_region,abs(disease_R0-b$disease_R0)<1e-8,
    metadata_sim_day_0==basename(sweep),
    map_lgl(tags,~identical(.x$scenario_label,b$scenario_label[[1]])))
  if (nrow(candidates)!=1) stop("Expected one calibration batch for ",b$geo_region)
  r <- candidates[1,]
  result <- summarize_simulation_batch(r)
  check <- inner_join(filter(weekly,geo_region==b$geo_region),result,by=c("geo_region","date"))
  stopifnot(nrow(check)==sum(weekly$geo_region==b$geo_region),
    all(abs(check$q0_5-check$fitted_median)<1e-8),
    all(abs(check$q0_025-check$pi95_lower)<1e-8),
    all(abs(check$q0_975-check$pi95_upper)<1e-8),
    all(abs(check$mean_generated-check$fitted_mean)<1e-8),
    all(check$sample_count==check$n_simulations),all(result$n_simulations>=2))
  result
})
write_csv(projections,file.path(out,"trajectory_prediction_intervals.csv"))
# Remove the obsolete generated mean-CI table to avoid confusing interval types.
old_ci_table <- file.path(out,"mean_trajectory_confidence_intervals.csv")
if (file.exists(old_ci_table)) unlink(old_ci_table)
plot_weekly <- projections %>% left_join(weekly %>% select(geo_region,date,observed),by=c("geo_region","date"))

# A short moving average suppresses isolated weekly reporting fluctuations.
# Significant peaks: >=35% of largest smoothed peak, >=4 weeks apart,
# and a valley >=20% below the smaller peak. Endpoint maxima are retained.
find_peaks <- function(y, dates, min_fraction = .35, separation = 4, valley_drop = .20, smooth = TRUE) {
  z <- if (smooth) as.numeric(stats::filter(y, rep(1/3, 3), sides = 2)) else y
  z[c(1, length(z))] <- y[c(1, length(y))]
  if (smooth) {
    consecutive <- c(FALSE, diff(dates)==7) & c(diff(dates)==7,FALSE)
    z[!consecutive] <- y[!consecutive]
  }
  candidates <- which(z >= c(-Inf, head(z, -1)) & z > c(tail(z, -1), -Inf) &
                        z >= min_fraction * max(z))
  kept <- integer()
  for (p in candidates[order(z[candidates], decreasing = TRUE)]) {
    distinct <- vapply(kept, function(k) abs(as.numeric(dates[p]-dates[k]))/7 >= separation &&
      min(z[seq(min(p,k), max(p,k))]) <= (1-valley_drop)*min(z[p], z[k]), logical(1))
    if (all(distinct)) kept <- c(kept, p)
  }
  list(index = sort(kept), smooth = z)
}
# Descriptive median-curve diagnostics, not probabilistic forecast scores.
# Thresholds are editorial screening choices; fitted Rm/E0 are never changed.
FIT_SCREENING <- list(max_nrmse = .15, max_peak_error = .20,
  max_total_error = .25, max_peak_week_error = 1,
  max_width20_error_weeks = 2, max_width50_error_weeks = 1.5,
  low_tail_deficit_fraction = .10)
wape <- function(o, p) sum(abs(p-o))/max(sum(o), 1)
peak_normalized_rmse <- function(o, p) sqrt(mean((p-o)^2))/max(o)

# Outermost crossings capture broad shoulders, including a later resurgence.
# Linear interpolation uses calendar dates; truncated windows are flagged.
peak_width <- function(y, dates, fraction) {
  dates <- as.numeric(dates)
  peak <- which.max(y)
  active <- which(y >= fraction*max(y))
  first <- min(active); last <- max(active)
  crossing <- function(i, j) dates[i] + (fraction*max(y)-y[i]) *
    (dates[j]-dates[i])/(y[j]-y[i])
  start <- if (first == 1L) dates[first] else crossing(first-1L, first)
  end <- if (last == length(y)) dates[last] else crossing(last, last+1L)
  rise <- (dates[peak]-start)/7
  decline <- (end-dates[peak])/7
  list(rise = rise, decline = decline, end = end,
    asymmetry = if (rise+decline > 0) (decline-rise)/(decline+rise) else NA_real_,
    censored = first == 1L || last == length(y))
}
curve_shape_metrics <- function(y, m, dates, fitted_mean = m) {
  o20 <- peak_width(y, dates, .20); p20 <- peak_width(m, dates, .20)
  o50 <- peak_width(y, dates, .50); p50 <- peak_width(m, dates, .50)
  tail <- as.numeric(dates) > o20$end
  total <- sum(y)
  tibble(
    rmse_median = sqrt(mean((m-y)^2)),
    nrmse_peak = peak_normalized_rmse(y,m),
    nrmse_mean_peak = peak_normalized_rmse(y,fitted_mean),
    observed_rise20_weeks = o20$rise, fitted_rise20_weeks = p20$rise,
    observed_decline20_weeks = o20$decline, fitted_decline20_weeks = p20$decline,
    rise20_error_weeks = p20$rise-o20$rise,
    decline20_error_weeks = p20$decline-o20$decline,
    observed_rise50_weeks = o50$rise, fitted_rise50_weeks = p50$rise,
    observed_decline50_weeks = o50$decline, fitted_decline50_weeks = p50$decline,
    rise50_error_weeks = p50$rise-o50$rise,
    decline50_error_weeks = p50$decline-o50$decline,
    observed_asymmetry20 = o20$asymmetry, fitted_asymmetry20 = p20$asymmetry,
    asymmetry20_error = p20$asymmetry-o20$asymmetry,
    observed_tail_fraction = sum(y[tail])/total,
    fitted_tail_fraction_of_observed_total = sum(m[tail])/total,
    tail_deficit_fraction = sum(y[tail]-m[tail])/total,
    shape_window_censored = o20$censored || p20$censored || o50$censored || p50$censored,
    prolonged_rise_missed = o20$rise-p20$rise > FIT_SCREENING$max_width20_error_weeks,
    prolonged_decline_missed = o20$decline-p20$decline > FIT_SCREENING$max_width20_error_weeks,
    low_tail_underestimated = sum(y[tail]-m[tail])/total > FIT_SCREENING$low_tail_deficit_fraction
  )
}
classify <- function(d) {
  y <- d$observed; m <- d$q0_5; pk <- find_peaks(y,d$date)
  raw_pk <- find_peaks(y,d$date, valley_drop = .10, smooth = FALSE)
  raw_ii <- sort(raw_pk$index[order(y[raw_pk$index],decreasing=TRUE)[seq_len(min(2,length(raw_pk$index)))]])
  # Chronological ordering of the two largest significant peaks.
  ii <- sort(pk$index[order(pk$smooth[pk$index], decreasing = TRUE)[seq_len(min(2, length(pk$index)))]])
  if (!length(ii)) stop("No observed peak for ", d$geo_region[[1]])
  mp <- which.max(m); op <- which.max(y)
  target <- ii[which.min(abs(as.numeric(d$date[ii]-d$date[mp])))]
  local <- which(abs(as.numeric(d$date-d$date[target]))<=14)
  local_error <- wape(y[local], m[local])
  local_good <- abs(as.numeric(d$date[mp]-d$date[target])) <= 7 && local_error <= .35
  shape <- curve_shape_metrics(y,m,d$date,d$mean_generated)
  core_shape_match <- max(abs(c(shape$rise20_error_weeks, shape$decline20_error_weeks))) <=
    FIT_SCREENING$max_width20_error_weeks &&
    max(abs(c(shape$rise50_error_weeks, shape$decline50_error_weeks))) <=
    FIT_SCREENING$max_width50_error_weeks
  # A clean observed single peak is required for showcase eligibility. Raw
  # secondary peaks are review flags, not proof of a biological second wave.
  global_good <- shape$nrmse_peak <= FIT_SCREENING$max_nrmse && core_shape_match &&
    !shape$shape_window_censored && length(raw_pk$index) == 1L &&
    abs(as.numeric(d$date[mp]-d$date[op]))/7 <= FIT_SCREENING$max_peak_week_error &&
    abs(max(m)/max(y)-1) <= FIT_SCREENING$max_peak_error &&
    abs(sum(m)/sum(y)-1) <= FIT_SCREENING$max_total_error
  middle <- length(ii) == 2 && d$date[mp] > d$date[ii[1]]+7 && d$date[mp] < d$date[ii[2]]-7
  position <- if (length(ii) == 1) "single_peak" else if (middle) "between_peaks" else
    if (target == ii[1]) "first_peak" else "second_peak"
  quality <- if (position == "single_peak") if (global_good) "good" else "bad" else
    if (middle) "bad" else if (local_good) "good" else "bad"
  early <- which(d$date < min(weekly$date)+28)
  early_ratio <- sum(m[early])/max(sum(y[early]),1)
  early_excess <- mean(m[early]-y[early])/max(y)
  similar <- length(ii) == 2 && min(pk$smooth[ii])/max(pk$smooth[ii]) >= .8
  result <- tibble(n_observed_weeks=nrow(d), expected_weeks=as.integer((max(weekly$date)-min(weekly$date))/7)+1L,
    incomplete_observation_window=nrow(d)<as.integer((max(weekly$date)-min(weekly$date))/7)+1L,
    early_observed_weeks=length(early), n_significant_peaks = length(pk$index),
    peak_1_date = d$date[ii[1]], peak_2_date = if (length(ii)==2) d$date[ii[2]] else as.Date(NA),
    peak_1_smoothed = pk$smooth[ii[1]], peak_2_smoothed = if (length(ii)==2) pk$smooth[ii[2]] else NA_real_,
    second_peak_tallest = length(ii)==2 && pk$smooth[ii[2]] > pk$smooth[ii[1]],
    similar_height_peaks = similar, fitted_peak_date = d$date[mp],
    raw_secondary_peak_flag = length(raw_pk$index) >= 2,
    raw_peak_count = length(raw_pk$index),
    raw_peak_1_date = d$date[raw_ii[1]],
    raw_peak_2_date = if (length(raw_ii)==2) d$date[raw_ii[2]] else as.Date(NA),
    raw_second_peak_tallest = length(raw_ii)==2 && y[raw_ii[2]]>y[raw_ii[1]],
    morphology_review_needed = length(pk$index) != length(raw_pk$index),
    epidemic_shape = if (length(pk$index)>2) "multiple_peaks" else
      if (length(ii)==1) "single_dominant_peak" else if (similar) "two_similar_height_peaks" else
      if (pk$smooth[ii[2]]>pk$smooth[ii[1]]) "two_peaks_second_tallest" else "two_peaks_first_tallest",
    fit_position = position, fit_quality = quality,
    category = paste(position, quality, sep = "_"),
    wape = wape(y,m), peak_window_wape = local_error,
    nmae_peak = mean(abs(y-m))/max(y),
    interval_coverage_95 = mean(y >= d$q0_025 & y <= d$q0_975),
    early_4week_ratio = early_ratio, early_excess_peak_fraction = early_excess,
    possible_excess_seeding = length(early)==4 && early_ratio >= 2 && early_excess >= .05,
    # An early fitted peak alone cannot diagnose an initialization error.
    review_reason = if (length(pk$index) >= 2L) "Multiple observed peaks; single fitted wave" else
      if (length(raw_pk$index) >= 2L) "Secondary peak / shoulder; morphology review" else
      if (shape$prolonged_rise_missed) "Observed rise longer than fitted rise" else
      if (shape$prolonged_decline_missed) "Observed decline longer than fitted decline" else
      if (shape$shape_window_censored) "Rise / decline truncated by observation window" else
      if (abs(as.numeric(d$date[mp]-d$date[op])) > 7) "Peak timing mismatch" else
      if (global_good && shape$low_tail_underestimated) "Single-peak core reproduced; low-level tail underestimated" else
      if (global_good) "Single-peak core reproduced" else
      if (shape$low_tail_underestimated) "Low-level tail underestimated" else
      if (length(early)==4 && early_ratio >= 2 && early_excess >= .05) "Early overshoot; investigate seeding" else
      "Curve width / amplitude / burden mismatch")
  bind_cols(result,shape)
}
screen <- weekly %>% group_by(geo_region) %>% group_modify(~classify(.x)) %>% ungroup()

# Descriptive mobility: population-weighted off-diagonal row sum of the input
# Q4 matrix. This is a matrix-weight summary, not measured travel volume.
context <- map_dfr(best$geo_region, function(state) {
  pop_path <- file.path(repo, "data", state, paste0("county_pop_by_age_",state,"_",acs,"ACS.csv"))
  flow_path <- file.path(repo, "data", state, paste0(state,"_Q4-2025_mobility-matrix.csv"))
  if (!file.exists(pop_path) || !file.exists(flow_path)) stop("Missing context inputs: ", state)
  pop <- read_table(pop_path)
  age <- grep("^[0-9]+(-[0-9]+|[+])$", names(pop), value = TRUE)
  stopifnot(length(age)>0, !anyDuplicated(pop$fips))
  county_weights <- rowSums(as.matrix(pop[age]))
  mat <- as.matrix(read_csv(flow_path, col_names = FALSE, show_col_types = FALSE, progress = FALSE))
  stopifnot(nrow(mat)==nrow(pop), ncol(mat)==nrow(pop), all(is.finite(mat)))
  diag(mat) <- 0
  selected_r0 <- best$disease_R0[match(state,best$geo_region)]
  seed_path <- file.path(sweep,"candidate_inputs",sprintf("INPUT_%s_ALL_INTERVENTIONS_R0-%.4f.json",state,selected_r0))
  seeded <- if (file.exists(seed_path)) {
    input <- jsonlite::fromJSON(seed_path)
    sum(as.numeric(input$initial_exposed$infected))
  } else NA_real_
  tibble(geo_region = state, county_count = nrow(pop), population = sum(county_weights),
    weighted_offcounty_mobility = weighted.mean(rowSums(mat), county_weights),
    initial_exposed = seeded, initial_exposed_per100k = seeded/sum(county_weights)*1e5,
    seed_source = if (file.exists(seed_path)) seed_path else NA_character_,
    population_source = pop_path, mobility_source = flow_path)
})
catalog <- screen %>% left_join(best %>% select(geo_region, disease_R0, sample_count,
  peak_lag_weeks, peak_ratio, total_ratio, mean_wis), by = "geo_region") %>%
  left_join(context, by = "geo_region") %>%
  mutate(original_plot = file.path(sweep,"plots",paste0(geo_region,"_final_r0_fit.png")))

# Showcase agreement in the observed single-peak core, then rank whole-curve
# median RMSE normalized by observed peak. Demography is context, not a score.
good_pool <- catalog %>%
  filter(category == "single_peak_good", !incomplete_observation_window) %>%
  arrange(nrmse_peak, abs(asymmetry20_error), geo_region)
if (nrow(good_pool) < 4L) stop("Fewer than four states meet the single-peak core screening rules. ",
  "Review the shape metrics and thresholds; no failing states are silently promoted.")
good <- head(good_pool$geo_region,4)
# Show distinct limitations of the saved fitted runs, not universal impossibility
# claims about the simulator. Use complete windows for the main comparisons.
bad <- character(); bad_labels <- character()
limitation_pool <- catalog %>% filter(!incomplete_observation_window)
pick_bad <- function(pool, label) {
  pool <- pool %>% filter(!geo_region %in% c(bad, good)) %>% arrange(desc(nrmse_peak),geo_region)
  if (nrow(pool)) {bad <<- c(bad,pool$geo_region[1]); bad_labels <<- c(bad_labels,label)}
}
pick_bad(filter(limitation_pool,n_significant_peaks>=2), "Multiple observed peaks; single fitted wave")
pick_bad(filter(limitation_pool,prolonged_rise_missed), "Observed rise longer than fitted rise")
pick_bad(filter(limitation_pool,prolonged_decline_missed), "Observed decline longer than fitted decline")
pick_bad(filter(limitation_pool,low_tail_underestimated), "Low-level tail underestimated")
while(length(bad)<4) {
  previous <- length(bad)
  pick_bad(filter(limitation_pool,fit_quality=="bad"),"Curve width / amplitude / burden mismatch")
  if (length(bad)==previous) stop("Fewer than four distinct fit-limitation examples.")
}
parse_states <- function(key, default) {
  value <- arg(key, "")
  if (nzchar(value)) trimws(strsplit(value,",",fixed=TRUE)[[1]]) else default
}
# Preserve metric-ranked panel order unless explicitly overridden.
good <- parse_states("--good-states",good)
bad_default <- bad
bad <- parse_states("--bad-states",bad)
stopifnot(length(good)==4, length(bad)==4, !anyDuplicated(c(good,bad)),
          all(c(good,bad) %in% catalog$geo_region))
if (!identical(bad,bad_default)) bad_labels <- catalog$review_reason[match(bad,catalog$geo_region)]
selection <- tibble(geo_region=c(good,bad), figure=rep(c("good_single_peak","bad_fit_reasons"),each=4),
                    panel=rep(LETTERS[1:4],2), panel_reason=c(catalog$review_reason[match(good,catalog$geo_region)],bad_labels)) %>%
  left_join(catalog, by="geo_region")
write_csv(catalog %>% arrange(category,wape),file.path(out,"state_fit_catalog.csv"))
write_csv(tibble(category=c("single_peak_good","single_peak_bad","first_peak_good","first_peak_bad",
  "between_peaks_bad","second_peak_good","second_peak_bad")) %>%
  left_join(count(catalog,category,name="state_count"),by="category") %>%
  mutate(state_count=replace_na(state_count,0L)),file.path(out,"category_counts.csv"))
write_csv(selection,file.path(out,"manuscript_panel_selection.csv"))
write_csv(weekly,file.path(out,"selected_rm_weekly_data.csv"))

# Figure-legend notes:
# Teal line: median of the individual simulation trajectories at selected Rm.
# Nested teal shading: central 95% (2.5th-97.5th percentiles, light), 80%
# (10th-90th percentiles), and 50% (25th-75th percentiles, dark) prediction
# intervals, computed with hubUtils::convert_output_type(). These are pointwise
# intervals across runs, following the hubverse convention, not t confidence
# intervals for the mean or simultaneous trajectory bands. Uncertainty is
# conditional on the fitted parameters; parameter uncertainty is not sampled.
# Red points and thin red line: observed weekly incident hospitalizations.
# Connect available observations in date order across missing weeks; these
# segments are visual guides and do not impute observations for scoring.
# Fits use the saved peak-height-selected Rm and complete scored MMWR weeks.
# Population/county context comes from the 2020-2024 ACS input tables. Mobility
# is the population-weighted off-county row sum of the Q4-2025 input matrix.
# Exact per-panel county, population, mobility, seed and fit metrics are saved
# in manuscript_panel_selection.csv for use when writing the figure legend.
# Categories are exploratory. Early overshoot suggests a seeding sensitivity
# analysis; it does not establish that excess seeding caused the mismatch.
scenario_order <- c("NONE","ANTIVIRAL","NPI","VACCINE","ALL_INTERVENTIONS","Observed")
# Reference 5c palette: olive, brown, gold, blue. Light cyan extends it for
# the fifth scenario, using the existing 9b scenario palette's NONE color.
scenario_colors <- c(NONE="#91D5DE",VACCINE="#596246",NPI="#bd6b4f",
  ANTIVIRAL="#f2ad2e",ALL_INTERVENTIONS="#2f8990",Observed="#c53c32")
scenario_names <- c(NONE="No interventions",VACCINE="Vaccine",NPI="NPI",
  ANTIVIRAL="Antiviral",ALL_INTERVENTIONS="All interventions",Observed="Observed")
panel_letters <- function(n) {
  vapply(seq_len(n),function(index) {
    label <- ""
    while (index>0) {
      label <- paste0(LETTERS[(index-1) %% 26+1],label)
      index <- (index-1) %/% 26
    }
    label
  },character(1))
}
make_figure <- function(states, filename, width=12, height=8.5, scenario_data=NULL,panel_labels=NULL,shared_y=FALSE,
                        panel_grobs=NULL,return_panels=FALSE,grid_rows=NULL) {
  if (is.null(panel_labels)) panel_labels <- panel_letters(length(states))
  stopifnot(length(panel_labels)==length(states),!anyDuplicated(panel_labels))
  comparison <- !is.null(scenario_data)
  panels <- if (!is.null(panel_grobs)) panel_grobs else map(seq_along(states), function(i) {
    state <- states[[i]]
    info <- catalog[match(state,catalog$geo_region),]
    d <- (if (comparison) scenario_data else plot_weekly) %>% filter(geo_region == state) %>%
      mutate(series=factor(scenario_label,levels=scenario_order))
    observations <- weekly %>% filter(geo_region==state,!is.na(observed)) %>%
      select(date,observed) %>% distinct() %>% arrange(date)
    bottom_row <- i > 2 * (ceiling(length(states)/2)-1)
    if (shared_y) bottom_row <- bottom_row || (i-1L) %% 8L >= 6L
    # Separate columns keep colons aligned in the regular proportional font.
    context_values <- c(scales::comma(info$population,accuracy=1),
      as.character(info$county_count),
      formatC(info$weighted_offcounty_mobility,format="f",digits=2))
    context_gp <- grid::gpar(fontsize=if (shared_y) 11 else 14,col="black")
    value_width <- max(do.call(grid::unit.c,lapply(context_values,function(value)
      grid::grobWidth(grid::textGrob(value,gp=context_gp)))))
    value_x <- grid::unit(1,"npc")-grid::unit(8,"pt")-value_width
    context_y <- grid::unit(1,"npc")-grid::unit(if (shared_y) c(10,23,36) else c(12,28,44),"pt")
    label_width <- grid::grobWidth(grid::textGrob("Population",gp=context_gp))
    context <- grid::grobTree(
      # Opaque backing masks grid lines only behind the annotation block.
      grid::rectGrob(x=grid::unit(1,"npc")-grid::unit(4,"pt"),
        y=grid::unit(1,"npc")-grid::unit(4,"pt"),
        width=value_width+label_width+grid::unit(17,"pt"),
        height=grid::unit(if (shared_y) 43 else 52,"pt"),just=c("right","top"),
        gp=grid::gpar(fill="white",col=NA)),
      grid::textGrob(c("Population","Counties","Mobility"),
        x=value_x-grid::unit(9,"pt"),y=context_y,just="right",gp=context_gp),
      grid::textGrob(rep(":",3),x=value_x-grid::unit(5,"pt"),y=context_y,gp=context_gp),
      grid::textGrob(context_values,x=value_x,y=context_y,just="left",gp=context_gp))
    if (comparison) {
      # Compact cumulative burdens accompany the shared labeled legend.
      # Rows: none (cyan), antiviral (gold), NPI (brown), vaccine (olive),
      # all interventions (blue), observed (red point). Rounded counts.
      totals <- scenario_totals %>% filter(geo_region==state)
      observed_row <- which(totals$scenario_label=="Observed")
      model_rows <- which(totals$scenario_label!="Observed")
      total_values <- scales::comma(totals$cumulative_total,accuracy=1)
      total_width <- max(do.call(grid::unit.c,lapply(total_values,function(value)
        grid::grobWidth(grid::textGrob(value,gp=context_gp)))))
      total_x <- grid::unit(1,"npc")-grid::unit(8,"pt")-total_width
      total_y <- grid::unit(1,"npc")-grid::unit(32+16*(seq_len(nrow(totals))-1),"pt")
      marker_x <- total_x-grid::unit(12,"pt")
      title_gp <- grid::gpar(fontsize=14,fontface="bold",col="black")
      title_width <- grid::grobWidth(grid::textGrob("Sum Inc Hosp",gp=title_gp))
      context <- grid::grobTree(
        grid::rectGrob(x=grid::unit(1,"npc")-grid::unit(4,"pt"),
          y=grid::unit(1,"npc")-grid::unit(4,"pt"),
          width=max(total_width+grid::unit(24,"pt"),title_width+grid::unit(8,"pt")),
          height=grid::unit(120,"pt"),
          just=c("right","top"),gp=grid::gpar(fill="white",col=NA)),
        grid::textGrob("Sum Inc Hosp",x=grid::unit(1,"npc")-grid::unit(8,"pt"),
          y=grid::unit(1,"npc")-grid::unit(12,"pt"),just="right",gp=title_gp),
        grid::pointsGrob(x=marker_x,y=total_y[observed_row],pch=16,size=grid::unit(7,"pt"),
          gp=grid::gpar(col=scenario_colors[["Observed"]])),
        grid::segmentsGrob(x0=marker_x-grid::unit(5,"pt"),x1=marker_x+grid::unit(5,"pt"),
          y0=total_y[model_rows],y1=total_y[model_rows],
          gp=grid::gpar(col=unname(scenario_colors[totals$scenario_label[model_rows]]),lwd=2)),
        grid::textGrob(total_values,x=total_x,y=total_y,just="left",gp=context_gp))
    }
    ggplot(d,aes(date)) +
      geom_ribbon(aes(ymin=pi95_lower,ymax=pi95_upper,fill=series),alpha=.15,show.legend=FALSE) +
      geom_ribbon(aes(ymin=pi80_lower,ymax=pi80_upper,fill=series),alpha=.20,show.legend=FALSE) +
      geom_ribbon(aes(ymin=pi50_lower,ymax=pi50_upper,fill=series),alpha=.30,show.legend=FALSE) +
      geom_line(aes(y=fitted_median,color=series),linewidth=.9) +
      geom_line(data=observations,aes(y=observed,color="Observed"),linewidth=.35,alpha=.65,show.legend=FALSE) +
      geom_point(data=observations,aes(y=observed,color="Observed"),size=1.5,
        show.legend=if (comparison) c(colour=TRUE,fill=FALSE) else FALSE) +
      scale_color_manual(NULL,values=scenario_colors,breaks=scenario_order,labels=scenario_names) +
      scale_fill_manual(NULL,values=scenario_colors,breaks=scenario_order,labels=scenario_names,guide="none") +
      annotation_custom(context,xmin=as.Date(-Inf,origin="1970-01-01"),
        xmax=as.Date(Inf,origin="1970-01-01")) +
      scale_x_date(date_breaks="2 months",date_labels="%b %Y",expand=expansion(mult=.02)) +
      # Reserve clear space above every trajectory/ribbon for the atlas inset.
      # At the fixed 3.5-inch row height, 60% expansion clears its 47-point
      # extent (43-point backing plus 4-point top offset).
      scale_y_continuous(labels=compact_axis_label,
        expand=expansion(mult=c(0,if (comparison) .06 else if (shared_y) .60 else .40))) +
      coord_cartesian(ylim=c(0,NA)) +
      labs(title=bquote(.(gsub("-"," ",state)) ~ " | " ~ R[m] == .(info$disease_R0)),
        x=if (bottom_row || shared_y) "Week ending date" else NULL,
        y=if (i %% 2 == 1 && !shared_y) "Weekly Incident Hosps" else NULL) +
      theme_bw(base_size=14) +
      theme(legend.position="none",legend.text=element_text(size=14),
        panel.grid.minor=element_blank(),
        panel.background=element_rect(fill="white",colour=NA),
        plot.background=element_rect(fill="white",colour=NA),
        axis.text=element_text(size=14,color="black"),
        axis.text.x=if (shared_y) element_text(size=14,color=if (bottom_row) "black" else "transparent") else
          if (bottom_row) element_text(size=14,color="black") else element_blank(),
        axis.ticks.x=if (shared_y) element_line(color=if (bottom_row) "black" else "transparent") else
          if (bottom_row) element_line() else element_blank(),
        axis.title=element_text(size=16),
        axis.title.x=element_text(margin=margin(t=8),
          color=if (shared_y && !bottom_row) "transparent" else "black"),
        axis.title.y=element_text(margin=margin(r=8)),
        plot.title=element_text(size=17,hjust=.5,margin=margin(b=6)),
        plot.margin=margin(t=12,r=12,b=8,l=10))
  })
  if (return_panels) return(panels)
  # Atlas grobs reserve identical axis space so every panel within a page
  # has the same plotting area, including its bottom row.
  if (!is.null(grid_rows)) {
    empty <- grid_rows*2L-length(panels)
    stopifnot(empty >= 0L)
    panels <- c(panels,rep(list(NULL),empty))
    panel_labels <- c(panel_labels,rep("",empty))
  }
  p <- cowplot::plot_grid(plotlist=panels,ncol=2,nrow=grid_rows,
    align=if (is.null(panel_grobs)) "v" else "none",axis="lr",
    labels=panel_labels,label_size=24,label_fontface="bold",
    label_x=.01,label_y=.99,hjust=0,vjust=1)
  if (shared_y) {
    # A shared title avoids collisions with postal labels in dense atlas pages.
    p <- cowplot::ggdraw() + cowplot::draw_plot(p,x=.045,width=.955) +
      cowplot::draw_label("Weekly Incident Hosps",x=.014,y=.5,angle=90,size=16)
  }
  if (comparison) {
    legend <- cowplot::get_legend(panels[[1]] + theme(legend.position="bottom") +
      guides(color=guide_legend(nrow=1,override.aes=list(linewidth=1.2,alpha=1,
        linetype=c(rep(1,5),0),shape=c(rep(NA,5),16),size=2.5))))
    p <- cowplot::plot_grid(p,legend,ncol=1,rel_heights=c(1,.075))
  }
  ggsave(file.path(figure_dir,paste0(filename,".png")),p,width=width,height=height,dpi=300,bg="white")
}
# Remove only PDF artifacts previously generated by this script (PNG-only).
old_pdfs <- list.files(figure_dir,pattern="^(good_single_peak_2x2|bad_fit_reasons_2x2|review_atlas_[0-9]{2})[.]pdf$",full.names=TRUE)
if (length(old_pdfs)) unlink(old_pdfs)
# Best eligible single-peak cores, selected from this run's actual diagnostics.
# Eligibility does not imply agreement in the low-intensity tail.
make_figure(good,"good_single_peak_2x2")
fit_legend <- paste("Points show observed weekly incident hospital admissions.",
  "The fitted line shows the median across saved realizations at the state-specific fitted Rm.",
  "Ribbons from darkest to lightest show central 50%, 80%, and 95% prediction intervals.",
  "Intervals describe variation across runs at fixed parameters.")
context_legend <- paste("The inset reports county count, population, and mobility for each state.",
  "Mobility is the population-weighted off-diagonal row sum of the Q4 2025 input matrix.")
write_manuscript_legend(figure_dir,"good_single_peak_2x2","Single-peak state fits",c(
  fit_legend, context_legend,
  paste("Panels A-D show",paste(gsub("-"," ",good),collapse=", "),
    "in order. Selection focuses on agreement near the observed peak.")
))
# Scenario-comparison companion: same A-D states and fitted Rm as good-fit
# figure; median lines and nested central 50/80/95% prediction intervals for
# NONE, ANTIVIRAL, NPI, VACCINE, ALL_INTERVENTIONS. Upper-right color-keyed
# cumulative totals accompany a shared labeled bottom legend; the observed
# red point is last in both. Demographic details are omitted from this figure.
# Observed is the sum over available observation weeks; scenarios show the
# median of each realization's sum over those same weeks, not a sum of medians.
# These are scenario counterfactuals at the calibrated Rm, not separate refits.
scenario_projections <- map_dfr(good,function(state) {
  r0 <- best$disease_R0[match(state,best$geo_region)]
  map_dfr(head(scenario_order,5),function(scenario) {
    if (scenario=="ALL_INTERVENTIONS") return(filter(projections,geo_region==state))
    candidates <- master_all %>% filter(geo_region==state,abs(disease_R0-r0)<1e-8,
      metadata_sim_day_0==basename(sweep),
      map_lgl(tags,~identical(.x$scenario_label,scenario) && is.null(.x$r0_search$candidate_R0)))
    if (nrow(candidates)!=1) stop("Expected one saved scenario batch for ",state," / ",scenario)
    summarize_simulation_batch(candidates[1,])
  })
})
stopifnot(nrow(distinct(scenario_projections,geo_region,scenario_label))==20,
  !anyDuplicated(scenario_projections[c("geo_region","scenario_label","date")]))
write_csv(scenario_projections,file.path(out,"good_states_five_scenarios_data.csv"))
scenario_totals <- map_dfr(good,function(state) {
  observations <- weekly %>% filter(geo_region==state)
  bind_rows(tibble(geo_region=state,scenario_label="Observed",
      cumulative_total=sum(observations$observed),summary_method="Sum of available observed weeks"),
    scenario_projections %>% filter(geo_region==state) %>%
      distinct(geo_region,scenario_label,cumulative_median) %>%
      transmute(geo_region,scenario_label,cumulative_total=cumulative_median,
        summary_method="Median of realization totals over available observed weeks")) %>%
    mutate(row_order=match(scenario_label,scenario_order),
      color=unname(scenario_colors[scenario_label]),
      first_observed_week=min(observations$date),last_observed_week=max(observations$date),
      observed_week_count=nrow(observations)) %>% arrange(row_order)
})
write_csv(scenario_totals,file.path(out,"good_states_five_scenarios_cumulative_totals.csv"))
make_figure(good,"good_states_five_scenarios_2x2",height=9,scenario_data=scenario_projections)
write_manuscript_legend(figure_dir,"good_states_five_scenarios_2x2",
  "Hospital admissions under five intervention scenarios",c(
    paste("Panels A-D show",paste(gsub("-"," ",good),collapse=", "),
      "in order. The five scenarios use the same fitted Rm within each state."),
    paste("Colored lines show scenario medians. Ribbons from darkest to lightest show central",
      "50%, 80%, and 95% prediction intervals. Red points show observed admissions."),
    paste("The inset lists cumulative incident admissions over the weeks with observations.",
      "Observed counts are summed across weeks. Simulated counts are summed within each",
      "realization and then summarized by their median.")
  ))

# Representative limitations selected from the current saved fits.
make_figure(bad,"bad_fit_reasons_2x2")
write_manuscript_legend(figure_dir,"bad_fit_reasons_2x2","Examples of state-fit limitations",c(
  fit_legend, context_legend,
  paste("Panels A-D show",paste(gsub("-"," ",bad),collapse=", "),
    "in order. The panels illustrate discrepancies in epidemic shape, timing, or tail burden.")
))
# Supplement: one alphabetical series for all remaining jurisdictions.
# Eight panels per page (four rows by two columns), labeled by postal abbreviation (including DC).
atlas_postal <- setNames(c(state.abb,"DC"),
  c(gsub(" ","-",state.name,fixed=TRUE),"District-of-Columbia"))
atlas_catalog <- catalog %>% filter(!geo_region %in% c(good,bad)) %>%
  arrange(geo_region,.locale="C") %>%
  mutate(page=as.integer(ceiling(row_number()/8)),
    atlas_panel=unname(atlas_postal[geo_region]))
stopifnot(!anyNA(atlas_catalog$atlas_panel), !anyDuplicated(atlas_catalog$atlas_panel))
# Align all axis/header grobs before pagination so each page's plotting regions
# are equal, even when tick-label widths differ between states.
atlas_grobs <- make_figure(atlas_catalog$geo_region,"",shared_y=TRUE,return_panels=TRUE)
atlas_grobs <- cowplot::align_plots(plotlist=atlas_grobs,align="hv",axis="tblr")
atlas_pages <- split(atlas_catalog$geo_region,atlas_catalog$page)
atlas_selection <- map_dfr(seq_along(atlas_pages),function(i) {
  states <- atlas_pages[[i]]
  filename <- sprintf("review_atlas_%02d",i)
  labels <- atlas_catalog$atlas_panel[match(states,atlas_catalog$geo_region)]
  grobs <- atlas_grobs[match(states,atlas_catalog$geo_region)]
  page_rows <- ceiling(length(states)/2)
  make_figure(states,filename,height=3.5*page_rows,panel_labels=labels,shared_y=TRUE,
    panel_grobs=grobs,grid_rows=page_rows)
  write_manuscript_legend(figure_dir,filename,
    sprintf("State fit atlas (page %d of %d)",i,length(atlas_pages)),c(
      fit_legend, context_legend,
      paste("Panels follow alphabetical state order and use two-letter postal abbreviations.",
        "States on this page:",paste(gsub("-"," ",states),collapse=", "))
    ))
  tibble(figure=paste0(filename,".png"),page=i,panel=labels,geo_region=states)
}) %>% left_join(atlas_catalog %>% select(geo_region,category,epidemic_shape,peak_1_date),
  by="geo_region")
stopifnot(!anyDuplicated(atlas_selection$geo_region),
  !any(atlas_selection$geo_region %in% c(good,bad)),
  setequal(atlas_selection$geo_region,atlas_catalog$geo_region))
write_csv(atlas_selection,file.path(out,"supplement_panel_selection.csv"))
# Remove only obsolete atlas pages generated by earlier runs of this script.
stale_atlas <- setdiff(unlist(lapply(unique(c(figure_dir,out)),list.files,
  pattern="^review_atlas_[0-9]{2}[.]png$",full.names=TRUE)),
  file.path(figure_dir,unique(atlas_selection$figure)))
if (length(stale_atlas)) unlink(stale_atlas)
summary_lines <- c(
  "# Manuscript state-fit screening (draft)", "",
  paste0("Source: `",sweep,"`. All ",nrow(catalog)," final-fit jurisdictions are included."),
  "Saved peak-height-selected Rm values and individual simulation runs are used without refitting. PNG figures show the median and nested central 50%, 80% and 95% prediction intervals, calculated with hubUtils::convert_output_type() following hubverse quantile conventions. These summarize variation across trajectories conditional on fixed fitted parameters, not confidence intervals for the mean or simultaneous bands. Parameter, structural and observation uncertainty are not added by these summaries. Screening uses the same saved medians.",
  "", "## Proposed panels", "",
  paste0("- Good single peak: ",paste(gsub("-"," ",good),collapse=", "),"."),
  paste0("- Fit limitations: ",paste(gsub("-"," ",bad),collapse=", "),"."),
  "", "## Screening rules", "",
  "These are provisional editorial categories, not validated goodness-of-fit tests. A state outside the good group need not be unusable.",
  "Single-peak core eligibility requires one significant smoothed peak and one raw peak, a complete observation window, uncensored width crossings, peak-normalized median RMSE <=15%, absolute peak timing error <=1 week, peak-height error <=20%, and median-curve total-burden error <=25%. Rise and decline width errors must each be <=2 weeks at 20% of peak and <=1.5 weeks at 50% of peak. These limits are provisional editorial thresholds, not validated tests.",
  "nrmse_peak = sqrt(mean((median-observed)^2))/max(observed). It is a descriptive discrepancy for the displayed median, not a proper probabilistic forecast score. nrmse_mean_peak also reports squared-error agreement of the ensemble mean; WAPE remains a secondary diagnostic. WIS does not select these panels.",
  "Rise and decline widths are calendar weeks from each curve's own raw maximum to its outermost 20% and 50% peak-height crossings, linearly interpolated between available weeks. They expose broad shoulders, slow rise and slow decline even when peak height and week match. Truncated crossings are flagged; missing observations are not interpolated into the scored residual series.",
  "Observed and fitted asymmetry20 = (decline20-rise20)/(decline20+rise20): positive means a longer decline, negative a longer rise. Symmetry is not required; matching each side's duration is required. Peaks/widths summarize observed shape, not mechanisms.",
  "Tail burden is measured after the last observed 20%-of-peak crossing, on common available dates. tail_deficit_fraction = sum(observed-median in that tail)/sum(all observed). A deficit >10% flags a missed low-intensity tail. This flag does not exclude an otherwise accurate peak core and is stated in its panel-selection reason. Core agreement is not whole-season agreement. No universal inability of PES is inferred from these saved runs.",
  "Interval coverage is reported separately and is not used to reward wide intervals.",
  "Incomplete observation windows are excluded from automatic main-panel selection. Metrics use available scored dates; plotted simulations cover all complete weeks. Missing observations are never replaced by zero.",
  "Peak timing and separation use calendar weeks. Three-week smoothing is applied only to consecutive observations. The early-overshoot flag requires all first four calendar weeks.",
  "Observed peak detection uses a centered three-week mean, >=35% relative height, >=4-week separation and a valley >=20% below the smaller peak.",
  "Two-peak positions use the two tallest detected peaks, ordered chronologically. Between means >1 week from both peaks; otherwise the nearest peak is the target.",
  "A good targeted peak requires <=1-week timing difference and <=0.35 WAPE within +/-2 weeks of that smoothed observed peak. It does not imply a good full-season fit.",
  "Similar-height means smaller/larger smoothed peak >=0.8. The second_peak_tallest field also identifies second peaks taller by any amount, including similar-height pairs.",
  "Raw data are also screened with a 10% valley rule. morphology_review_needed flags disagreement with smoothed detection; shallow shoulders and reporting noise need visual judgment.",
  "Early overshoot requires first-four-week fitted/observed total >=2 and average excess >=5% of observed peak. This is a seeding hypothesis, not causal evidence; initial exposed counts and input JSON sources are recorded.",
  "", "## County, population and mobility context", "",
  "Population and county counts come from the local county age-population inputs. Counties include county equivalents.",
  "Mobility is the population-weighted off-diagonal row sum of the Q4-2025 input matrix, in original county row order. It is a descriptive matrix summary, not measured travel volume or a causal effect.",
  paste0("Good panels are the four lowest nrmse_peak states among ",nrow(good_pool)," eligible single-peak cores; ties use absolute asymmetry error and state name. Population, counties and mobility are descriptive context, not selection criteria."),
  "The limitation panel seeks multiple peaks, a prolonged observed rise, a prolonged observed decline, and a missed low-intensity tail, using distinct states and prioritizing larger nrmse_peak within each reason. If a mechanism is absent, remaining slots use other curve mismatches. These are descriptive examples, not causal diagnoses.",
  "State selection can be overridden with --good-states and --bad-states (four comma-separated states each); categories and diagnostic reasons remain those calculated from the saved data.",
  "", "## Files", "",
  "- good_single_peak_2x2.png and bad_fit_reasons_2x2.png: manuscript drafts (PNG only).",
  "- good_states_five_scenarios_2x2.png and good_states_five_scenarios_data.csv: five-scenario companion for the good-fit states, using saved runs at each state's fitted Rm. A shared labeled legend sits below the panels. The upper-right block titled Sum Inc Hosp shows colored markers and cumulative counts: none (cyan), antiviral (gold), NPI (brown), vaccine (olive), all interventions (blue), observed (red point, last). Observed totals sum available weeks; model totals are medians of per-realization sums over those same weeks, rounded to whole counts in the figure.",
  "- good_states_five_scenarios_cumulative_totals.csv: exact cumulative counts, summary methods, colors and observation windows.",
  "- trajectory_prediction_intervals.csv: median, central 50/80/95% prediction limits, means, sample counts and simulation sources.",
  "- state_fit_catalog.csv: all categories, metrics, peak dates, review flags, input context and source paths.",
  "- manuscript_panel_selection.csv: exact panel membership and reasons.",
  "- selected_rm_weekly_data.csv: plotted observations and simulations for every jurisdiction.",
  paste0("- review_atlas_01 through ",sprintf("review_atlas_%02d",length(atlas_pages)),
    ": supplementary PNG figures for the ",nrow(atlas_catalog),
    " jurisdictions absent from the two main figures, in one alphabetical series. Each page has eight panels in four rows by two columns, except the final partial page. Atlas pages are 12 inches wide with a fixed 3.5-inch row height and a shared y-axis title: complete pages are 14 inches tall; the final three-panel page is 7 inches tall. All plotting regions are the same physical size across all pages, with hidden date labels retaining their space. Compact 11-point population/county/mobility insets sit in reserved upper space clear of all trajectories and prediction ribbons. Panels use two-letter state postal abbreviations (including DC), with alphabetical state order across pages and no grouping by peak shape."),
  "- supplement_panel_selection.csv: alphabetical state index with figure filename, page, postal abbreviation in the panel column, fit category, observed shape and peak-date mapping.",
  "", "## Supplement shape counts (descriptive only)", "",
  "| Category | Jurisdictions |", "|---|---:|",
  {groups <- count(atlas_catalog,epidemic_shape); sprintf("| %s | %d |",groups$epidemic_shape,groups$n)},
  "", "## All-state classifications", "",
  "| State | Category | Epidemic shape | Weeks | Shape review? | Peak-normalized RMSE | Tail deficit |", "|---|---|---|---:|---|---:|---:|",
  sprintf("| %s | %s | %s | %d | %s | %.3f | %.3f |",gsub("-"," ",catalog$geo_region),catalog$category,catalog$epidemic_shape,catalog$n_observed_weeks,
    ifelse(catalog$morphology_review_needed,"Yes",""),catalog$nrmse_peak,catalog$tail_deficit_fraction))
writeLines(summary_lines,file.path(out,"README.md"))
writeLines(capture.output(sessionInfo()),file.path(out,"session_info.txt"))
print(selection %>% select(figure,panel,geo_region,category,nrmse_peak,
  rise20_error_weeks,decline20_error_weeks,tail_deficit_fraction,panel_reason))
message("Wrote manuscript figures to ",figure_dir,"; supporting tables and notes to ",out)
