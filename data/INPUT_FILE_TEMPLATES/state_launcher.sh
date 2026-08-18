#!/bin/bash

#SBATCH -J state_test                    # Job name
#SBATCH -o state_test.%j.o               # Name of stdout output file (%j expands to jobId)
#SBATCH -e state_test.%j.e               # Name of stderr output file (%j expands to jobId)
#SBATCH -p normal                        # Queue name, small is for <=2 nodes, normal 3+
#SBATCH -N 2                  	         # Total number of nodes requested
#SBATCH -n 64                            # Total number of tasks, LS6 32 per node so N*32 = max
#SBATCH -t 24:00:00            	         # Run time (hh:mm:ss), max 48hr for any job
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
#    Always check the first command of state_commands.txt runs as expected on a development node


# Load launcher
module load launcher

# Configure launcher
EXECUTABLE=$TACC_LAUNCHER_DIR/init_launcher
PRUN=$TACC_LAUNCHER_DIR/paramrun
CONTROL_FILE=state_commands.txt
export LAUNCHER_JOB_FILE=state_commands.txt
export LAUNCHER_WORKDIR=`pwd`
export LAUNCHER_SCHED=interleaved

# Start launcher
$PRUN $EXECUTABLE $CONTROL_FILE
