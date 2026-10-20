# Run with Rscript --vanilla test/test_wis_recovery.R from the repository root.
# Extract the runner without sourcing the script's pipeline side effects.
expressions <- parse(file = "scripts/5c_Rm_sweep_all_interventions.R")
runner <- Filter(function(expr) {
  is.call(expr) && identical(expr[[1]], as.name("<-")) &&
    identical(expr[[2]], as.name("run_candidate"))
}, as.list(expressions))
stopifnot(length(runner) == 1L)

env <- new.env(parent = baseenv())
env$reuse_existing <- TRUE
env$recover_existing <- TRUE
env$run_sims <- TRUE
env$r0_key <- function(r0) sprintf("%.4f", r0)
env$complete_metadata_for_candidate <- function(...) "saved-metadata.json"
env$system2 <- function(...) stop("TEST FAILURE: simulator was launched")
eval(runner[[1]], env)
stopifnot(identical(env$run_candidate("input.json", "Texas", 2.15), "saved-metadata.json"))

env$complete_metadata_for_candidate <- function(...) NA_character_
for (run_sims in c(TRUE, FALSE)) {
  env$run_sims <- run_sims
  error <- tryCatch(env$run_candidate("input.json", "Texas", 2.15), error = identity)
  stopifnot(inherits(error, "error"),
            grepl("Recovery needs complete saved output for Texas R0=2.1500", conditionMessage(error), fixed = TRUE))
}
cat("Recovery reuses saved candidates and refuses to launch missing candidates.\n")
