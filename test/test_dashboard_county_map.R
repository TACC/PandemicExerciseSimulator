# Run from the repository root: Rscript --vanilla test/test_dashboard_county_map.R
# Verify county/age/replicate isolation, denominators, missing data and Plotly output.
app <- new.env(parent = globalenv())
expressions <- parse("scripts/7b_sim_dashboard_app.R")
for (expression in expressions[-length(expressions)]) eval(expression, app)
temporary <- tempfile("county-map-")
dir.create(file.path(temporary, "sim_data", "scenario", "batch"), recursive = TRUE)
app$DATA_ROOT <- temporary
app$PARQUET_ROOT <- file.path(temporary, "sim_data")
rows <- expand.grid(fips_id = c(1001L, 1003L), day = c(0L, 1L), sim_id = c(0L, 1L, 2L, 10L))
rows$batch_num <- "batch"
rows$scenario_hash <- "scenario"
rows$IS_L_U_age0 <- ifelse(rows$day == 0, 0, ifelse(rows$sim_id == 0, 10, 90))
rows$IS_H_V_age0 <- ifelse(rows$day == 0, 0, 5)
rows$IS_L_U_age1 <- ifelse(rows$day == 0, 0, 20)
rows$IS <- rows$IS_L_U_age0 + rows$IS_H_V_age0 + rows$IS_L_U_age1
arrow::write_parquet(rows, file.path(app$PARQUET_ROOT, "scenario", "batch", "nodes.parquet"))
population <- data.frame(fips = c("01001", "01003"), check.names = FALSE,
  "0-4" = c(100, 200), "5-17" = c(200, 300), "18-49" = c(300, 400),
  "50-64" = c(400, 500), "65+" = c(500, 600))
readr::write_csv(population, file.path(temporary, "population.csv"))
metadata <- data.frame(geo_region = "Alabama", data_population = "population.csv")
p <- app$county_map_population(metadata, "0")
stopifnot(identical(p$population, c(100, 200)))
all_pop <- app$county_map_population(metadata, "all")
stopifnot(identical(all_pop$population, c(1500, 2000)))
stopifnot(identical(app$county_map_runs("scenario")$sim_id, c("0", "1", "2", "10")))
series <- app$county_map_timeseries("scenario", "batch", "0", "IS", "0")
stopifnot(nrow(series) == 4, all(series$count[series$day == 0] == 0),
          all(series$count[series$day == 1] == 15))
other <- app$county_map_timeseries("scenario", "batch", "1", "IS", "0")
stopifnot(all(other$count[other$day == 1] == 95))
all_ages <- app$county_map_timeseries("scenario", "batch", "0", "IS", "all")
stopifnot(all(all_ages$count[all_ages$day == 1] == 35))
counties <- data.frame(fips = c("01001", "01003", "01005"), county = c("A", "B", "Missing"))
frame <- app$county_map_frame(series, counties, p, 1, "percent")
stopifnot(nrow(frame) == 3, identical(frame$count[1:2], c(15, 15)),
          identical(frame$percent[1:2], c(15, 7.5)), is.na(frame$count[3]),
          is.na(frame$z[3]), grepl("No simulation data", frame$text[3]))
zero_pop <- p
zero_pop$population[1] <- 0
stopifnot(is.na(app$county_map_frame(series, counties, zero_pop, 1, "percent")$percent[1]))
counts <- app$county_map_frame(series, counties, p, 1, "count")
stopifnot(all.equal(counts$z[1:2], log1p(c(15, 15))))

# All boundary assets parse, have unique five-digit FIPS, and valid viewports.
for (path in list.files(file.path(app$MAP_ASSET_ROOT, "map_boundaries"), full.names = TRUE)) {
  state <- sub("_counties_2023.geojson$", "", basename(path))
  geometry <- app$county_map_geometry(state)
  stopifnot(!anyDuplicated(geometry$counties$fips), all(nchar(geometry$counties$fips) == 5),
            all(is.finite(unlist(geometry$center))), is.finite(geometry$zoom))
}
# A fixture keeps helper tests independent of which states were deployed.
app$MAP_ASSET_ROOT <- file.path(temporary, "assets")
dir.create(file.path(app$MAP_ASSET_ROOT, "map_boundaries"), recursive = TRUE)
features <- lapply(seq_len(nrow(counties)), function(i) list(type = "Feature",
 properties = list(GEOID = counties$fips[i], NAMELSAD = counties$county[i]),
 geometry = list(type = "Polygon", coordinates = list(list(c(-88+i/10, 31),
   c(-88+i/10, 32), c(-87+i/10, 32), c(-88+i/10, 31))))))
jsonlite::write_json(list(type = "FeatureCollection", features = features),
 file.path(app$MAP_ASSET_ROOT, "map_boundaries", "Alabama_counties_2023.geojson"), auto_unbox = TRUE)
geometry <- app$county_map_geometry("Alabama")
figure <- plotly::plotly_build(app$county_map_figure(geometry, frame, p, "percent", "Test", "Alabama"))
stopifnot(length(figure$x$data) == 2, figure$x$data[[2]]$zmax == log1p(100),
          figure$x$layout$mapbox$style == "white-bg",
          length(figure$x$layout$mapbox$`_fitBounds`$bounds) == 2)
unlinked <- data.frame(geo_region = "Alabama", data_population = "does-not-exist.csv")
stopifnot(inherits(tryCatch(app$county_map_population(unlinked, "all"), error = identity), "error"))
unlink(temporary, recursive = TRUE)
cat("County map: age totals, population percentages, day/replicate isolation, missing records and available bundled boundaries passed.\n")
