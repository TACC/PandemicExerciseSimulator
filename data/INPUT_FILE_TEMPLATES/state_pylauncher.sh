#!/bin/bash

#SBATCH -J state_test                    # Job name
#SBATCH -o state_test.%j.o               # Name of stdout output file (%j expands to jobId)
#SBATCH -e state_test.%j.e               # Name of stderr output file (%j expands to jobId)
#SBATCH -p normal                        # Queue name, development for testing, normal for full runs
#SBATCH -N 4                             # Total number of nodes requested
#SBATCH --ntasks-per-node=1              # Used by Slurm; PyLauncher controls its own command placement
#SBATCH -t 48:00:00                      # Run time (hh:mm:ss), max 48hr for any job
#SBATCH -A XXXXXXXX                      # Allocation name, change to your allocation name
#SBATCH --mail-user=emjavan@utexas.edu   # Email for notifications, change to your email
#SBATCH --mail-type=all                  # Type of notifications, begin, end, fail, all

#### NOTES ON USE ####
# 1. This is an sbatch job launcher script example for Lonestar6 on TACC to do basic parallelization.
# 2. Each task runs independently and writes to independent files, i.e. no task is waiting
#     for another to finish or over-writing the outputs of another.
#    Every line of state_commands.txt is an independent task, so when one finishes
#     the next line begins until no more tasks exist or job time runs out.
# 3. The number of compute nodes you need depends on total tasks and how long they run for.
# 4. PyLauncher does not use --ntasks-per-node to decide how many commands to start.
#    Concurrency is controlled in state_pylauncher.py by cores=4.
#    On each node, total node cores / cores gives the number of commands pylauncher can start.
# 5. Always check the first command of state_commands.txt runs as expected on a development node.
#    $SCRATCH deletes unused files after a couple weeks so `git restore .` may be needed from the root dir.
# 6. Generated LS6 task commands use ls6_container_exec.sh for container R/Python.
#    Host Python below runs PyLauncher; the simulations run inside the image.
# 7. Slurm DOES use the task request: keep --ntasks-per-node=1 with the requested -N.
#    Do not also set -n/--ntasks to a total smaller than the node count. For example,
#    -N 4 with -n 1 can produce "can't run 1 processes on 4 nodes" and reduce the
#    allocation to one node. Remove the total-task directive instead of relying on
#    PyLauncher ignoring it; Slurm processes these directives before PyLauncher starts.

# Personal R package library for anything added independent of container
export APPTAINERENV_PES_R_LIBRARY="$WORK/pes-r-library"

# Load apptainer to run the Python and R singularity container
module load tacc-apptainer

# Load pylauncher
module load pylauncher

# Start pylauncher
python3 state_pylauncher.py
