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
wape <- function(o, p) sum(abs(p-o))/max(sum(o), 1)
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
  global_good <- wape(y,m) <= .45 && abs(as.numeric(d$date[mp]-d$date[op])) <= 7 &&
    abs(max(m)/max(y)-1) <= .20 && abs(sum(m)/sum(y)-1) <= .25
  middle <- length(ii) == 2 && d$date[mp] > d$date[ii[1]]+7 && d$date[mp] < d$date[ii[2]]-7
  position <- if (length(ii) == 1) "single_peak" else if (middle) "between_peaks" else
    if (target == ii[1]) "first_peak" else "second_peak"
  quality <- if (position == "single_peak") if (global_good) "good" else "bad" else
    if (middle) "bad" else if (local_good) "good" else "bad"
  early <- which(d$date < min(weekly$date)+28)
  early_ratio <- sum(m[early])/max(sum(y[early]),1)
  early_excess <- mean(m[early]-y[early])/max(y)
  similar <- length(ii) == 2 && min(pk$smooth[ii])/max(pk$smooth[ii]) >= .8
  tibble(n_observed_weeks=nrow(d), expected_weeks=as.integer((max(weekly$date)-min(weekly$date))/7)+1L,
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
    review_reason = if (length(early)==4 && early_ratio >= 2 && early_excess >= .05) "Early overshoot; investigate seeding" else
      if (middle) "Fitted peak falls between observed peaks" else
      if (similar) "Two observed peaks of similar height" else
      if (length(ii)==2 && target==ii[1]) "Targets first observed peak" else
      if (length(ii)==2) "Targets second observed peak" else
      if (abs(mp-op)>1) "Peak timing mismatch" else
      if (!global_good) "Epidemic width / total burden mismatch" else "Good single-peak fit")
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

# Exhaustive four-state selection maximizes the sum of pairwise distances in
# standardized log(population), log(counties), and mobility, within good fits.
good_pool <- catalog %>% filter(category == "single_peak_good", !incomplete_observation_window) %>% arrange(wape)
diverse_four <- function(pool) {
  if (nrow(pool)<4) stop("Fewer than four good single-peak states; review thresholds explicitly.")
  x <- cbind(log(pool$population), log(pool$county_count), pool$weighted_offcounty_mobility)
  x <- scale(x); x[!is.finite(x)] <- 0
  distance <- as.matrix(dist(x))
  sets <- combn(nrow(pool),4)
  score <- apply(sets,2,function(i) sum(distance[i,i])/2)
  pool$geo_region[sets[,which.max(score)]]
}
good <- diverse_four(good_pool)
# Choose distinct examples, one per mechanism where available.
bad <- character(); bad_labels <- character()
pick_bad <- function(pool, label) {
  pool <- pool %>% filter(!geo_region %in% c(bad, good)) %>% arrange(desc(wape))
  if (nrow(pool)) {bad <<- c(bad,pool$geo_region[1]); bad_labels <<- c(bad_labels,label)}
}
pick_bad(filter(catalog,fit_quality=="bad", possible_excess_seeding), "Early overshoot; seeding hypothesis")
pick_bad(filter(catalog,fit_quality=="bad", similar_height_peaks), "Similar-height observed peaks")
pick_bad(filter(catalog,fit_position=="between_peaks"), "Fitted peak between observed peaks")
pick_bad(filter(catalog,fit_quality=="bad", second_peak_tallest, fit_position=="second_peak"), "Poor fit to taller second peak")
while(length(bad)<4) {
  previous <- length(bad)
  pick_bad(filter(catalog,fit_quality=="bad"),"Timing / epidemic-shape mismatch")
  if (length(bad)==previous) stop("Fewer than four distinct bad-fit examples.")
}
parse_states <- function(key, default) {
  value <- arg(key, "")
  if (nzchar(value)) trimws(strsplit(value,",",fixed=TRUE)[[1]]) else default
}
# Manuscript reading order within the selected examples (A, B, C, D).
good <- good[order(match(good,c("New-York","New-Jersey","Washington","Colorado")))]
bad_order <- order(match(bad,c("Pennsylvania","North-Dakota","Florida","Arizona")))
bad <- bad[bad_order]
bad_labels <- bad_labels[bad_order]
good <- parse_states("--good-states",good)
bad_default <- bad
bad <- parse_states("--bad-states",bad)
stopifnot(length(good)==4, length(bad)==4, !anyDuplicated(c(good,bad)),
          all(c(good,bad) %in% catalog$geo_region))
if (!identical(bad,bad_default)) bad_labels <- catalog$review_reason[match(bad,catalog$geo_region)]
selection <- tibble(geo_region=c(good,bad), figure=rep(c("good_single_peak","bad_fit_reasons"),each=4),
                    panel=rep(LETTERS[1:4],2), panel_reason=c(rep("Good single-peak fit",4),bad_labels)) %>%
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
make_figure <- function(states, filename, width=12, height=8.5, scenario_data=NULL,panel_labels=NULL) {
  if (is.null(panel_labels)) panel_labels <- panel_letters(length(states))
  stopifnot(length(panel_labels)==length(states),!anyDuplicated(panel_labels))
  comparison <- !is.null(scenario_data)
  panels <- map(seq_along(states), function(i) {
    state <- states[[i]]
    info <- catalog[match(state,catalog$geo_region),]
    d <- (if (comparison) scenario_data else plot_weekly) %>% filter(geo_region == state) %>%
      mutate(series=factor(scenario_label,levels=scenario_order))
    observations <- weekly %>% filter(geo_region==state,!is.na(observed)) %>%
      select(date,observed) %>% distinct() %>% arrange(date)
    bottom_row <- i > 2 * (ceiling(length(states)/2)-1)
    # Separate columns keep colons aligned in the regular proportional font.
    context_values <- c(scales::comma(info$population,accuracy=1),
      as.character(info$county_count),
      formatC(info$weighted_offcounty_mobility,format="f",digits=2))
    context_gp <- grid::gpar(fontsize=14,col="black")
    value_width <- max(do.call(grid::unit.c,lapply(context_values,function(value)
      grid::grobWidth(grid::textGrob(value,gp=context_gp)))))
    value_x <- grid::unit(1,"npc")-grid::unit(8,"pt")-value_width
    context_y <- grid::unit(1,"npc")-grid::unit(c(12,28,44),"pt")
    label_width <- grid::grobWidth(grid::textGrob("Population",gp=context_gp))
    context <- grid::grobTree(
      # Opaque backing masks grid lines only behind the annotation block.
      grid::rectGrob(x=grid::unit(1,"npc")-grid::unit(4,"pt"),
        y=grid::unit(1,"npc")-grid::unit(4,"pt"),
        width=value_width+label_width+grid::unit(17,"pt"),
        height=grid::unit(52,"pt"),just=c("right","top"),
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
      # Only the annotated figures need extra room for the context block.
      scale_y_continuous(labels=compact_axis_label,
        expand=expansion(mult=c(0,if (comparison) .06 else .40))) +
      coord_cartesian(ylim=c(0,NA)) +
      labs(title=bquote(.(gsub("-"," ",state)) ~ " | " ~ R[m] == .(info$disease_R0)),
        x=if (bottom_row) "Week ending date" else NULL,
        y=if (i %% 2 == 1) "Weekly Incident Hosps" else NULL) +
      theme_bw(base_size=14) +
      theme(legend.position="none",legend.text=element_text(size=14),
        panel.grid.minor=element_blank(),
        panel.background=element_rect(fill="white",colour=NA),
        plot.background=element_rect(fill="white",colour=NA),
        axis.text=element_text(size=14,color="black"),
        axis.text.x=if (bottom_row) element_text(size=14,color="black") else element_blank(),
        axis.ticks.x=if (bottom_row) element_line() else element_blank(),
        axis.title=element_text(size=16),
        axis.title.x=element_text(margin=margin(t=8)),
        axis.title.y=element_text(margin=margin(r=8)),
        plot.title=element_text(size=17,hjust=.5,margin=margin(b=6)),
        plot.margin=margin(t=12,r=12,b=8,l=10))
  })
  # Align panel sides without padding the upper rows for hidden date labels.
  p <- cowplot::plot_grid(plotlist=panels,ncol=2,align="v",axis="lr",
    labels=panel_labels,label_size=24,label_fontface="bold",
    label_x=.01,label_y=.99,hjust=0,vjust=1)
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
# Good-fit figure: A New York, B New Jersey, C Washington, D Colorado by default.
# These relatively good single-peak fits span 21-64 counties and 5.86-19.85M
# people. Washington follows the full curve best; late-season tails remain
# underpredicted in the other panels. Selection can be overridden at the CLI.
make_figure(good,"good_single_peak_2x2")
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

# Fit-limitation figure, default panels:
# A Pennsylvania: early overshoot; excess initial exposure is a hypothesis.
# B North Dakota: fitted epidemic peaks too early, with a shape mismatch.
# C Florida: two observed peaks of similar height; fit targets the first wave.
# D Arizona: fitted peak falls between two observed peaks (second is taller).
make_figure(bad,"bad_fit_reasons_2x2")
# Supplement: separate single/double-peak figure sets, excluding main figures.
# Cluster earlier peaks before later peaks, paginate at eight panels, and
# alphabetize each page. Letters continue across pages within each set (A-Z,
# AA, AB, ...), restarting at A when a new shape set begins. Partial pages
# finish each set so the double-peak set never shares a single-peak page.
atlas_catalog <- catalog %>% filter(!geo_region %in% c(good,bad)) %>%
  mutate(shape_cluster=case_when(n_significant_peaks==1 ~ "Single dominant peak",
    n_significant_peaks==2 ~ "Two peaks",TRUE ~ "Multiple peaks"),
    shape_order=match(shape_cluster,c("Single dominant peak","Two peaks","Multiple peaks"))) %>%
  arrange(shape_order,peak_1_date,epidemic_shape,geo_region,.locale="C") %>%
  group_by(shape_cluster) %>% mutate(set_page=as.integer(ceiling(row_number()/8))) %>%
  ungroup() %>% arrange(shape_order,set_page,geo_region,.locale="C") %>%
  group_by(shape_cluster) %>% mutate(set_panel=panel_letters(n())) %>% ungroup() %>%
  mutate(page=as.integer(factor(paste(shape_order,set_page,sep="_"),
    levels=unique(paste(shape_order,set_page,sep="_")))))
atlas_pages <- split(atlas_catalog$geo_region,atlas_catalog$page)
atlas_selection <- map_dfr(seq_along(atlas_pages),function(i) {
  states <- atlas_pages[[i]]
  filename <- sprintf("review_atlas_%02d",i)
  labels <- atlas_catalog$set_panel[match(states,atlas_catalog$geo_region)]
  make_figure(states,filename,height=3.5*ceiling(length(states)/2),panel_labels=labels)
  tibble(figure=paste0(filename,".png"),page=i,panel=labels,geo_region=states)
}) %>% left_join(atlas_catalog %>% select(geo_region,category,epidemic_shape,shape_cluster,set_page,peak_1_date),
  by="geo_region")
stopifnot(!anyDuplicated(atlas_selection$geo_region),
  !any(atlas_selection$geo_region %in% c(good,bad)),
  setequal(atlas_selection$geo_region,atlas_catalog$geo_region))
write_csv(atlas_selection,file.path(out,"supplement_panel_selection.csv"))
# Remove only obsolete atlas pages generated by earlier runs of this script.
stale_atlas <- setdiff(list.files(out,pattern="^review_atlas_[0-9]{2}[.]png$",full.names=TRUE),
  file.path(out,unique(atlas_selection$figure)))
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
  "Good single peak requires WAPE <=0.45, absolute peak timing error <=1 week, peak-height error <=20%, and total-burden error <=25%.",
  "WAPE is sum(abs(fitted median - observed))/sum(observed). The 0.45 cutoff defines relatively good examples for this draft; a stricter 0.35 cutoff retains only Washington and New York in this run.",
  "Even these good examples can miss the late-season tail. Interval coverage is reported separately and is not used to reward wide intervals.",
  "The weekly score table omits unavailable observations: Arkansas, Oklahoma and West Virginia have 27 weeks, DC 23 and Wyoming 10 (versus 28). Their classifications require coverage review; they are excluded from automatic good-panel selection. Metrics use scored dates; plotted simulations cover all complete weeks. Missing observations are never replaced by zero.",
  "Peak timing and separation use calendar weeks. Three-week smoothing is applied only to consecutive observations. The early-overshoot flag requires all first four calendar weeks.",
  "Observed peak detection uses a centered three-week mean, >=35% relative height, >=4-week separation and a valley >=20% below the smaller peak.",
  "Two-peak positions use the two tallest detected peaks, ordered chronologically. Between means >1 week from both peaks; otherwise the nearest peak is the target.",
  "A good targeted peak requires <=1-week timing difference and <=0.35 WAPE within +/-2 weeks of that smoothed observed peak. It does not imply a good full-season fit.",
  "Similar-height means smaller/larger smoothed peak >=0.8. The second_peak_tallest field also identifies second peaks taller by any amount, including similar-height pairs.",
  "Raw data are also screened with a 10% valley rule. morphology_review_needed flags disagreement with smoothed detection; shallow shoulders and reporting noise need visual judgment.",
  "No selected fit targets the second significant peak under the current smoothed rule; those categories are supported but empty in this run.",
  "Early overshoot requires first-four-week fitted/observed total >=2 and average excess >=5% of observed peak. This is a seeding hypothesis, not causal evidence; initial exposed counts and input JSON sources are recorded.",
  "", "## County, population and mobility context", "",
  "Population and county counts come from the local county age-population inputs. Counties include county equivalents.",
  "Mobility is the population-weighted off-diagonal row sum of the Q4-2025 input matrix, in original county row order. It is a descriptive matrix summary, not measured travel volume or a causal effect.",
  "Good-panel selection maximizes pairwise diversity in standardized log population, log county count and mobility among eligible states. Exactly four qualify in this run, limiting diversity (21-64 counties and 5.86-19.85 million people).",
  "The bad panel prioritizes distinct available reasons, then larger WAPE. State selection can be overridden with --good-states and --bad-states (four comma-separated states each).",
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
    " jurisdictions absent from the two main figures, in separate single-peak and double-peak figure sets (with a multiple-peak set if needed). Each set has eight panels per page except its final partial page. Earlier peaks precede later peaks in page assignment; states are alphabetical within each page. Panel letters continue across a set's pages (A-Z, AA, AB, ...), restarting at A for the next set."),
  "- supplement_panel_selection.csv: global supplement page, within-set page, continuous panel letter, state, fit category, observed shape and peak-date mapping.",
  "", "## Supplement groups", "",
  "| Category | Jurisdictions |", "|---|---:|",
  {groups <- count(atlas_catalog,shape_cluster); sprintf("| %s | %d |",groups$shape_cluster,groups$n)},
  "", "## All-state classifications", "",
  "| State | Category | Epidemic shape | Weeks | Shape review? | WAPE |", "|---|---|---|---:|---|---:|",
  sprintf("| %s | %s | %s | %d | %s | %.3f |",gsub("-"," ",catalog$geo_region),catalog$category,catalog$epidemic_shape,catalog$n_observed_weeks,
    ifelse(catalog$morphology_review_needed,"Yes",""),catalog$wape))
writeLines(summary_lines,file.path(out,"README.md"))
writeLines(capture.output(sessionInfo()),file.path(out,"session_info.txt"))
print(selection %>% select(figure,panel,geo_region,category,wape,county_count,population,weighted_offcounty_mobility))
message("Wrote manuscript figures to ",figure_dir,"; supporting tables and notes to ",out)
