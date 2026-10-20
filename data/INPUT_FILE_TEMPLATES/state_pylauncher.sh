#!/bin/bash

#SBATCH -J state_test                    # Job name
#SBATCH -o state_test.%j.o               # Name of stdout output file (%j expands to jobId)
#SBATCH -e state_test.%j.e               # Name of stderr output file (%j expands to jobId)
#SBATCH -p normal                        # Queue name, development for testing, normal for full runs
#SBATCH -N 2                             # Total number of nodes requested
#SBATCH -n 2                             # Ignored by pylauncher task placement; keep one Slurm task per node
#SBATCH -t 24:00:00                      # Run time (hh:mm:ss), max 48hr for any job
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
# 4. Pylauncher ignores #SBATCH -n for deciding how many simulator commands to start.
#    Concurrency is controlled in state_pylauncher.py by cores=4.
#    On each node, total node cores / cores gives the number of commands pylauncher can start.
# 5. Always check the first command of state_commands.txt runs as expected on a development node.
#    $SCRATCH deletes unused files after a couple weeks so `git restore .` may be needed from the root dir.
# 6. The version of R on the command line differs from using a TAP interactive session
#    The difference matters when trying to use tidycensus, but everything else in pipeline is okay

# Load R, will load the newest version available on LS6
module load Rstats

# Load pylauncher
module load pylauncher

# Start pylauncher
python3 state_pylauncher.py
