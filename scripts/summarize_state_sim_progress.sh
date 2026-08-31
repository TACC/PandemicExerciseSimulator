#!/usr/bin/env bash
set -euo pipefail

# Summarize output from find_missing_state_sims.sh.
# Usage:
#   bash scripts/summarize_state_sim_progress.sh state_sim_progress.csv

STATUS_CSV="${1:-state_sim_progress.csv}"

if [[ ! -f "$STATUS_CSV" ]]; then
   echo "ERROR: status CSV not found: $STATUS_CSV" >&2
   exit 1
fi

awk -F',' '
function unquote(x) {
   gsub(/^"/, "", x)
   gsub(/"$/, "", x)
   gsub(/""/, "\"", x)
   return x
}

NR == 1 {
   for (i = 1; i <= NF; i++) {
      name = unquote($i)
      col[name] = i
   }
   next
}

{
   state = unquote($col["state"])
   scenario = unquote($col["scenario"])
   finished = $col["finished"] + 0
   missing = $col["missing"] + 0

   status = "not_started"
   if (missing == 0) {
      status = "done"
   } else if (finished > 0) {
      status = "running"
   }

   command_count++
   command_status[status]++

   state_seen[state] = 1
   state_total[state]++
   state_status[state, status]++
   state_finished[state] += finished
   state_missing[state] += missing

   scenario_seen[scenario] = 1
   scenario_total[scenario]++
   scenario_status[scenario, status]++
   scenario_finished[scenario] += finished
   scenario_missing[scenario] += missing
}

END {
   print "COMMANDS"
   printf "  done=%d running=%d not_started=%d total=%d\n\n", \
      command_status["done"], command_status["running"], command_status["not_started"], command_count

   print "STATES"
   for (state in state_seen) {
      rollup = "not_started"
      if (state_status[state, "done"] == state_total[state]) {
         rollup = "done"
      } else if (state_status[state, "running"] > 0 || state_status[state, "done"] > 0) {
         rollup = "running"
      }

      state_rollup[rollup]++
      printf "  %-24s %-11s scenarios=%2d done=%2d running=%2d not_started=%2d sims_done=%4d sims_left=%4d\n", \
         state, rollup, state_total[state], state_status[state, "done"], \
         state_status[state, "running"], state_status[state, "not_started"], \
         state_finished[state], state_missing[state]
   }

   printf "\nSTATE TOTALS\n"
   printf "  done=%d running=%d not_started=%d total=%d\n\n", \
      state_rollup["done"], state_rollup["running"], state_rollup["not_started"], \
      state_rollup["done"] + state_rollup["running"] + state_rollup["not_started"]

   print "SCENARIOS"
   for (scenario in scenario_seen) {
      rollup = "not_started"
      if (scenario_status[scenario, "done"] == scenario_total[scenario]) {
         rollup = "done"
      } else if (scenario_status[scenario, "running"] > 0 || scenario_status[scenario, "done"] > 0) {
         rollup = "running"
      }

      scenario_rollup[rollup]++
      printf "  %-18s %-11s states=%2d done=%2d running=%2d not_started=%2d sims_done=%4d sims_left=%4d\n", \
         scenario, rollup, scenario_total[scenario], scenario_status[scenario, "done"], \
         scenario_status[scenario, "running"], scenario_status[scenario, "not_started"], \
         scenario_finished[scenario], scenario_missing[scenario]
   }

   printf "\nSCENARIO TOTALS\n"
   printf "  done=%d running=%d not_started=%d total=%d\n", \
      scenario_rollup["done"], scenario_rollup["running"], scenario_rollup["not_started"], \
      scenario_rollup["done"] + scenario_rollup["running"] + scenario_rollup["not_started"]
}
' "$STATUS_CSV"
