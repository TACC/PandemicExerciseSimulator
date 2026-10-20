#!/bin/bash
# Run one pipeline command in the image; keep PyLauncher on the host.
set -euo pipefail

image=${PES_CONTAINER_IMAGE:-}
if [[ ${1:-} == --image ]]; then
  image=${2:?--image requires a SIF path}
  shift 2
fi
if [[ -z "$image" ]]; then
  if [[ -z ${WORK:-} ]]; then
    echo 'Set WORK (TACC work directory) or PES_CONTAINER_IMAGE (SIF path).' >&2
    exit 2
  fi
  image="$WORK/pes_pipeline_r442_py312.sif"
fi
if [[ $# -eq 0 ]]; then
  echo 'Usage: bash ls6_container_exec.sh [--image /path/to/image.sif] COMMAND [ARGS...]' >&2
  exit 2
fi
if [[ ! -f "$image" ]]; then
  echo "Container image does not exist: $image" >&2
  exit 2
fi
if ! command -v apptainer >/dev/null 2>&1; then
  echo 'Apptainer is unavailable; load tacc-apptainer in the job launcher.' >&2
  exit 2
fi
scripts_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(dirname -- "$scripts_dir")
profile="$repo_dir/containers/ls6-runtime.Rprofile"
if [[ ! -f "$profile" ]]; then
  echo "Container R startup file does not exist: $profile" >&2
  exit 2
fi

# Explicit Apptainer injection variables survive --cleanenv. Discard the host
# Python workarounds, which would hide or conflict with the image's libraries.
unset APPTAINERENV_APPEND_PATH APPTAINERENV_PREPEND_PATH
unset APPTAINERENV_LD_LIBRARY_PATH APPTAINERENV_PATH
unset SINGULARITYENV_APPEND_PATH SINGULARITYENV_PREPEND_PATH
unset SINGULARITYENV_LD_LIBRARY_PATH SINGULARITYENV_PATH

# Binding the checkout separately also supports installations outside /scratch.
# Do not bind /opt: it contains the Python and R installations in the image.
exec apptainer exec --cleanenv \
  --bind "${PES_CONTAINER_BINDPATH:-/work,/scratch}" \
  --bind "$repo_dir:$repo_dir" \
  --env "R_PROFILE_USER=$profile" \
  --env R_ENVIRON_USER=/dev/null \
  "$image" "$@"
