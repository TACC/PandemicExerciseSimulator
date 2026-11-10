# Run from the repository root: Rscript --vanilla test/test_dashboard_map_bundle.R
# Exercise real bundle preparation with small fixture data and skip renv snapshot.
work <- tempfile('map-bundle-'); dir.create(work)
dir.create(file.path(work,'scripts'))
dir.create(file.path(work,'data','Texas'),recursive=TRUE)
file.copy('scripts/7b_sim_dashboard_app.R',file.path(work,'scripts','7b_sim_dashboard_app.R'))
# Exercise the real downloader with a fixture transport, without source data/ assets.
fixture_assets <- normalizePath('deploy/shinyapps/PandemicSimExplorer/data/dashboard_map_assets')
downloads <- character()
fail_download <- FALSE
fixture_download <- function(url, destfile, ...) {
 downloads <<- c(downloads, url)
 if (fail_download) stop('fixture network unavailable')
 relative <- if (endsWith(url, '/LICENSE')) 'LICENSE' else file.path('map_boundaries', basename(url))
 stopifnot(file.copy(file.path(fixture_assets, relative), destfile))
 0L
}
pop_name <- 'county_pop_by_age_Texas_2020-2024ACS.csv'
file.copy(file.path('data/Texas',pop_name),file.path(work,'data/Texas',pop_name))
source_data <- file.path(work,'output');dir.create(file.path(source_data,'sim_data','hash','batch'),recursive=TRUE)
dir.create(file.path(source_data,'validation_fit_data'))
meta <- data.frame(geo_region='Texas',scenario_hash='hash',batch_num='batch',
 metadata_tags_json='{"scenario_label":"NONE"}',file_path='WEB_OUTPUTS/metadata.json',
 validation_json=NA_character_,validation_fit_data_file=NA_character_,
 created_at_utc='2026-10-26 00:00:00',data_population=paste0('/scratch/data/Texas/',pop_name))
readr::write_csv(meta,file.path(source_data,'metadata_master.csv'))
arrow::write_parquet(data.frame(x=1),file.path(source_data,'scenario_features.parquet'))
arrow::write_parquet(data.frame(x=1),file.path(source_data,'sim_data/hash/batch/nodes.parquet'))
steps <- parse('scripts/8_prepare_shinyapps_bundle.R')
prepare <- function(limit) {
 env <- new.env(parent=globalenv());env$PIPELINE_OUTPUT_DIR <- 'output'
 env$DASHBOARD_PREVIEW_STATES <- 'Texas';env$DASHBOARD_PREVIEW_SCENARIOS <- 'NONE'
 env$DASHBOARD_MAX_BUNDLE_BYTES <- limit
 for (step in steps) {
  if (identical(step, quote(write_renv_lockfile()))) next
  if (is.call(step) && identical(step[[1]],as.name('<-')) && identical(step[[2]],as.name('pipeline_output_dir'))) env$repo_root <- work
  if (is.call(step) && identical(step[[1]],as.name('<-')) && identical(step[[2]],as.name('map_source'))) {
   downloader <- env$download_county_map_assets
   env$download_county_map_assets <- function(states) downloader(states, download = fixture_download)
  }
  eval(step,env)
 }
 env
}
env <- prepare(5e9)
bundle <- env$bundle_dir
m <- readr::read_csv(file.path(bundle,'data/metadata_master.csv'),show_col_types=FALSE)
stopifnot(m$data_population==file.path('map_population',pop_name),
 file.exists(file.path(bundle,'data',m$data_population)),
 file.exists(file.path(bundle,'data/dashboard_map_assets/map_boundaries/Texas_counties_2023.geojson')))
stopifnot(!dir.exists(file.path(work, 'data', 'dashboard_map_assets')),
 length(downloads) == 2L, all(grepl('12242450febc494f30616a191f743ca6f1638cd6', downloads)),
 any(endsWith(downloads, '/Texas_counties_2023.geojson')), any(endsWith(downloads, '/LICENSE')),
 !dir.exists(env$map_source))
config <- readLines(env$publisher_config)
stopifnot(any(grepl('/data/map_population/',config,fixed=TRUE)))
# Existing-config update path, then verify a tiny payload budget actually rejects.
file.create(file.path(bundle, 'data', 'obsolete-state.parquet'))
env2 <- prepare(5e9)
stopifnot(!file.exists(file.path(bundle,'data','obsolete-state.parquet')),
 file.exists(file.path(source_data,'sim_data/hash/batch/nodes.parquet')))
stopifnot(sum(grepl('/data/map_population/',readLines(env2$publisher_config),fixed=TRUE))==1)
# Reuse a different configuration when the saved hosted deployment binds to it.
existing_name <- 'Already-published-app'
existing_config <- file.path(env2$publisher_config_dir,paste0(existing_name,'.toml'))
file.copy(env2$publisher_config,existing_config)
records <- file.path(env2$publisher_config_dir,'deployments');dir.create(records)
record <- file.path(records,'existing.toml')
record_text <- c(paste0('configuration_name = "',existing_name,'"'), 'id = "keep-existing-app-id"')
writeLines(record_text,record)
env3 <- prepare(5e9)
stopifnot(env3$publisher_config_name==existing_name,
 identical(readLines(record),record_text),
 sum(grepl('/data/map_population/',readLines(existing_config),fixed=TRUE))==1)
error <- tryCatch(prepare(1),error=identity)
stopifnot(inherits(error,'error'),grepl('exceeds the budget',conditionMessage(error)),
 file.exists(file.path(bundle,'data',m$data_population)))
# A network failure occurs before any existing deployment data is replaced.
fail_download <- TRUE
error <- tryCatch(prepare(5e9), error=identity)
stopifnot(inherits(error, 'error'), grepl('fixture network unavailable', conditionMessage(error)),
 file.exists(file.path(bundle,'data',m$data_population)), identical(readLines(record),record_text))
unlink(work,recursive=TRUE)
cat('Bundle: selected geometry, existing population input, portable metadata paths, publisher config and entire-directory budget passed.\n')
