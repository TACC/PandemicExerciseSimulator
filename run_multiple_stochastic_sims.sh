#!/bin/bash

run_days=500
for i in {1..10}
do
   # Define the full sim subdirectory path
   init_sim_dir="OUTPUT_small_stochastic_min1/OUTPUT_small_stochastic_min1_sim0"
   sim_dir="OUTPUT_small_stochastic_min1/OUTPUT_small_stochastic_min1_sim${i}"

   # Create the sim directory if it doesn't exist
   mkdir -p "${sim_dir}"

   # Copy the original input JSON to a temp file
   cp data/texas/INPUT_small.json tmp_input.json

   # Replace only the sim subfolder name using the sim_dir variable
   sed -i '' "s|${init_sim_dir}|${sim_dir}|" tmp_input.json
  
   # print header of file to confirm it changed
   echo ""
   echo "✨🌸✨"
   head -n2 tmp_input.json 
   echo "✨🌸✨"

   # Run the simulation
   poetry run python3 src/simulator.py -l INFO -d ${run_days} -i tmp_input.json

   mv plot.png stochastic_plot_${i}.png
   echo "🌙🌙🌙 Finished sim set ${i}"
   echo ""
done

# Run deterministic model as well
# This assumes all params are what you want already, e.g. mobility turned off etc
mkdir -p OUTPUT_small_deterministic_min1/
echo "✨🌸🌙 Starting deterministic model"
poetry run python3 src/simulator.py -l INFO -d ${run_days} -i data/texas/INPUT_small_deterministic.json
mv plot.png deterministic_plot.png
echo "🌙🌙🌙 Finished deterministic model"

# Clean up temp file
rm tmp_input.json