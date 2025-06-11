#!/bin/bash

for i in {0..7}
do
   # Define the full sim subdirectory path
   sim_dir="OUTPUT_small_stochastic/OUTPUT_small_stochastic_sim${i}"

   # Create the sim directory if it doesn't exist
   mkdir -p "${sim_dir}"

   # Copy the original input JSON to a temp file
   cp data/texas/INPUT_small.json tmp_input.json

   # Replace only the sim subfolder name using the sim_dir variable
   sed -i '' "s|OUTPUT_small_stochastic/OUTPUT_small_stochastic_sim0|${sim_dir}|" tmp_input.json
  
   # 
   head -n2 tmp_input.json 

   # Run the simulation
   poetry run python3 src/simulator.py -l INFO -d 50 -i tmp_input.json

   echo "✨🌸🌙 Finished sim set ${i}"
done

# Clean up temp file
rm tmp_input.json