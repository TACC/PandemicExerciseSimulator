# Run from the repository root: Rscript --vanilla test/test_dashboard_bundle_paths.R
# Exercise section 8's path setup without copying data or snapshotting packages.
expressions <- as.list(parse("scripts/8_prepare_shinyapps_bundle.R"))
text <- vapply(expressions, function(expr) paste(deparse(expr), collapse = " "), character(1))
start <- which(startsWith(text, "cmd_args <-"))
end <- which(startsWith(text, "pipeline_output_dir <-")) - 1L
fixture <- tempfile("dashboard-paths-")
dir.create(file.path(fixture, "scripts"), recursive = TRUE)
fixture <- normalizePath(fixture)
bundle_script <- file.path(fixture, "scripts", "8_prepare_shinyapps_bundle.R")
writeLines(c(vapply(expressions[start:end], function(expr)
  paste(deparse(expr), collapse = "\n"), character(1)),
  "stopifnot(identical(repo_root, normalizePath('..')))",
  "cat('Dashboard root resolved correctly.\\n')"), bundle_script)

run_checks <- function() {
  original_dir <- getwd()
  on.exit(setwd(original_dir))
  on.exit(unlink(fixture, recursive = TRUE), add = TRUE)
  setwd(file.path(fixture, "scripts"))
  # Reproduce script 0's relative --file argument after its setwd('scripts').
  env <- new.env(parent = globalenv())
  env$commandArgs <- function(...) "--file=scripts/0_run_full_pipeline_US.R"
  source("8_prepare_shinyapps_bundle.R", local = env)
  stopifnot(identical(env$repo_root, fixture))
  # Standalone execution must resolve the same root from --file.
  status <- system2(file.path(R.home("bin"), "Rscript"),
    c("--vanilla", shQuote(bundle_script)))
  stopifnot(identical(status, 0L))
  # Interactive source() from the repository root also uses the source file.
  setwd(fixture)
  env <- new.env(parent = globalenv())
  env$commandArgs <- function(...) character()
  # The fixture's final assertion assumes scripts/; test the setup expressions here.
  writeLines(vapply(expressions[start:end], function(expr)
    paste(deparse(expr), collapse = "\n"), character(1)), bundle_script)
  source("scripts/8_prepare_shinyapps_bundle.R", local = env)
  stopifnot(identical(env$repo_root, fixture))
}
run_checks()
cat("Dashboard paths passed for pipeline, standalone, and interactive sourcing.\n")
