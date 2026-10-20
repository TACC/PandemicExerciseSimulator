# R startup in the geospatial base image resets PATH. Restore the image's
# Python and Poetry after site startup has completed, before running scripts.
Sys.setenv(
  PATH = paste("/opt/pes-python/bin", "/opt/pes-poetry/bin",
    Sys.getenv("PATH"), sep = .Platform$path.sep),
  VIRTUAL_ENV = "/opt/pes-python",
  POETRY_VIRTUALENVS_CREATE = "false",
  PYTHONNOUSERSITE = "1"
)
.libPaths(c("/opt/pes-r-library", .libPaths()))
