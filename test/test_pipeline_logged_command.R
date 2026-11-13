# Run from the repository root: Rscript --vanilla test/test_pipeline_logged_command.R
# Reproduce a host login profile overriding the container's Poetry PATH.
local({
  env <- new.env(parent = globalenv())
  sys.source("scripts/0_pipeline_helpers.R", env)
  temporary <- tempfile("logged command ")
  dir.create(temporary)
  on.exit(unlink(temporary, recursive = TRUE), add = TRUE)
  runtime_bin <- file.path(temporary, "container bin")
  host_bin <- file.path(temporary, "host bin")
  dir.create(runtime_bin)
  dir.create(host_bin)
  old_path <- Sys.getenv("PATH")
  on.exit(Sys.setenv(PATH = old_path), add = TRUE)
  write_executable <- function(path, lines) {
    writeLines(c("#!/bin/bash", lines), path)
    Sys.chmod(path, "0755")
  }
  # Emulate the PATH reset caused by LS6 login startup, without touching HOME.
  write_executable(file.path(runtime_bin, "bash"), c(
    'if [[ "$1" == -lc ]]; then',
    paste0("  export PATH=", shQuote(paste(host_bin, old_path, sep = .Platform$path.sep))),
    '  shift; exec /bin/bash -c "$@"',
    'fi',
    'exec /bin/bash "$@"'
  ))
  write_executable(file.path(host_bin, "poetry"), c(
    'echo "host Poetry: libpython3.9.so.1.0 missing" >&2', 'exit 127'
  ))
  write_executable(file.path(runtime_bin, "poetry"), c(
    'printf "cwd=%s\\narg=%s\\n" "$PWD" "$1"',
    'echo "CENSUS_API_KEY=test-secret" >&2', 'exit 23'
  ))
  Sys.setenv(PATH = paste(runtime_bin, old_path, sep = .Platform$path.sep))
  env$pipeline_log_file <- file.path(temporary, "pipeline log.txt")
  status <- env$run_logged_command("poetry", "argument with spaces ' and $",
    workdir = temporary)
  logged <- readLines(env$pipeline_log_file)
  stopifnot(
    identical(status, 23L),
    normalizePath(sub("^cwd=", "", logged[startsWith(logged, "cwd=")])) ==
      normalizePath(temporary),
    "arg=argument with spaces ' and $" %in% logged,
    "CENSUS_API_KEY=<redacted>" %in% logged,
    !any(grepl("test-secret|host Poetry", logged))
  )
})
cat("Logged command environment, quoting, redaction, and exit status checks passed.\n")
