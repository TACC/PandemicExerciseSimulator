#!/usr/bin/env bash
set -euo pipefail

# Summarize output from find_missing_state_sims.sh.
# Run from STATE_WKLYFIT_TEST/TACC_FILES on TACC:
#   bash ../../scripts/summarize_state_sim_progress.sh state_sim_progress.csv

STATUS_CSV="${1:-state_sim_progress.csv}"

if [[ ! -f "$STATUS_CSV" ]]; then
   echo "ERROR: status CSV not found: $STATUS_CSV" >&2
   exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

awk -F',' '
function unquote(x) {
   gsub(/^"/, "", x)
   gsub(/"$/, "", x)
   gsub(/""/, "\"", x)
   return x
}

function read_time_file(path,    line,n,i,name,time_col,val) {
   rt_sum = 0
   rt_count = 0

   if (path == "" || path == "NA") return

   if ((getline line < path) <= 0) {
      close(path)
      return
   }

   n = split(line, header, ",")
   time_col = 0
   for (i = 1; i <= n; i++) {
      name = unquote(header[i])
      if (name == "time_seconds") time_col = i
   }

   if (!time_col) {
      close(path)
      return
   }

   while ((getline line < path) > 0) {
      n = split(line, fields, ",")
      val = unquote(fields[time_col])
      if (val ~ /^-?[0-9]+([.][0-9]+)?$/) {
         rt_sum += val
         rt_count++
      }
   }
   close(path)
}

function mean_or_na(sum, count) {
   if (count <= 0) return "NA"
   return sprintf("%.1f", sum / count)
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
   timing_file = unquote($col["timing_file"])
   finished = $col["finished"] + 0
   missing = $col["missing"] + 0

   read_time_file(timing_file)

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
   state_time_sum[state] += rt_sum
   state_time_count[state] += rt_count

   scenario_seen[scenario] = 1
   scenario_total[scenario]++
   scenario_status[scenario, status]++
   scenario_finished[scenario] += finished
   scenario_missing[scenario] += missing
   scenario_time_sum[scenario] += rt_sum
   scenario_time_count[scenario] += rt_count
}

END {
   printf "COMMANDS\n" > summary_file
   printf "  done=%d running=%d not_started=%d total=%d\n\n", \
      command_status["done"], command_status["running"], command_status["not_started"], command_count > summary_file

   for (state in state_seen) {
      rollup = "not_started"
      if (state_status[state, "done"] == state_total[state]) {
         rollup = "done"
      } else if (state_status[state, "running"] > 0 || state_status[state, "done"] > 0) {
         rollup = "running"
      }

      state_rollup[rollup]++
      printf "  %-24s %-11s scenarios=%2d done=%2d running=%2d not_started=%2d sims_done=%4d sims_left=%4d mean_sec=%s\n", \
         state, rollup, state_total[state], state_status[state, "done"], \
         state_status[state, "running"], state_status[state, "not_started"], \
         state_finished[state], state_missing[state], \
         mean_or_na(state_time_sum[state], state_time_count[state]) > state_file
   }

   printf "\nSTATE TOTALS\n" > state_totals_file
   printf "  done=%d running=%d not_started=%d total=%d\n\n", \
      state_rollup["done"], state_rollup["running"], state_rollup["not_started"], \
      state_rollup["done"] + state_rollup["running"] + state_rollup["not_started"] > state_totals_file

   for (scenario in scenario_seen) {
      rollup = "not_started"
      if (scenario_status[scenario, "done"] == scenario_total[scenario]) {
         rollup = "done"
      } else if (scenario_status[scenario, "running"] > 0 || scenario_status[scenario, "done"] > 0) {
         rollup = "running"
      }

      scenario_rollup[rollup]++
      printf "  %-18s %-11s states=%2d done=%2d running=%2d not_started=%2d sims_done=%4d sims_left=%4d mean_sec=%s\n", \
         scenario, rollup, scenario_total[scenario], scenario_status[scenario, "done"], \
         scenario_status[scenario, "running"], scenario_status[scenario, "not_started"], \
         scenario_finished[scenario], scenario_missing[scenario], \
         mean_or_na(scenario_time_sum[scenario], scenario_time_count[scenario]) > scenario_file
   }

   printf "\nSCENARIO TOTALS\n" > scenario_totals_file
   printf "  done=%d running=%d not_started=%d total=%d\n", \
      scenario_rollup["done"], scenario_rollup["running"], scenario_rollup["not_started"], \
      scenario_rollup["done"] + scenario_rollup["running"] + scenario_rollup["not_started"] > scenario_totals_file
}
' summary_file="$TMP_DIR/summary.txt" \
  state_file="$TMP_DIR/states.txt" \
  state_totals_file="$TMP_DIR/state_totals.txt" \
  scenario_file="$TMP_DIR/scenarios.txt" \
  scenario_totals_file="$TMP_DIR/scenario_totals.txt" \
  "$STATUS_CSV"

cat "$TMP_DIR/summary.txt"
echo "STATES"
sort "$TMP_DIR/states.txt"
cat "$TMP_DIR/state_totals.txt"
echo "SCENARIOS"
sort "$TMP_DIR/scenarios.txt"
cat "$TMP_DIR/scenario_totals.txt"
