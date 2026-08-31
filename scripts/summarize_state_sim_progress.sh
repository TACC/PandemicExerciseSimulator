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
STATUS_DIR="$(cd "$(dirname "$STATUS_CSV")" && pwd)"
STATUS_BASE="$(basename "$STATUS_CSV")"
STATUS_ABS="$STATUS_DIR/$STATUS_BASE"

find_latest_timing() {
   local output_dir="$1"

   [[ -n "$output_dir" && "$output_dir" != "NA" ]] || return 0

   if [[ -d "$output_dir" ]]; then
      find "$output_dir" -maxdepth 1 -type f -name 'simulation_times_batch-*.csv' -print0 \
         | xargs -0 ls -t 2>/dev/null \
         | head -n 1
      return 0
   fi

   if [[ "$output_dir" != /* && -d "$STATUS_DIR/$output_dir" ]]; then
      find "$STATUS_DIR/$output_dir" -maxdepth 1 -type f -name 'simulation_times_batch-*.csv' -print0 \
         | xargs -0 ls -t 2>/dev/null \
         | head -n 1
      return 0
   fi
}

RUNTIME_TSV="$TMP_DIR/runtime_lookup.tsv"
awk -F',' '
function unquote(x) {
   gsub(/\r$/, "", x)
   gsub(/^"/, "", x)
   gsub(/"$/, "", x)
   gsub(/""/, "\"", x)
   return x
}
NR == 1 {
   for (i = 1; i <= NF; i++) {
      col[unquote($i)] = i
   }
   next
}
{
   timing_file = unquote($col["timing_file"])
   output_dir = unquote($col["output_dir"])
   print NR - 1 "\t" timing_file "\t" output_dir
}
' "$STATUS_ABS" | while IFS=$'\t' read -r row_num timing_file output_dir; do
   resolved="$timing_file"

   if [[ -z "$resolved" || "$resolved" == "NA" || ! -f "$resolved" ]]; then
      if [[ "$timing_file" != /* && -f "$STATUS_DIR/$timing_file" ]]; then
         resolved="$STATUS_DIR/$timing_file"
      else
         resolved="$(find_latest_timing "$output_dir")"
      fi
   fi

   if [[ -z "$resolved" || "$resolved" == "NA" || ! -f "$resolved" ]]; then
      printf '%s\t0\t0\n' "$row_num"
      continue
   fi

   awk -F',' -v row_num="$row_num" '
      NR == 1 {
         for (i = 1; i <= NF; i++) {
            gsub(/\r$/, "", $i)
            gsub(/^"|"$/, "", $i)
            if ($i == "time_seconds") time_col = i
         }
         next
      }
      time_col {
         val = $time_col
         gsub(/\r$/, "", val)
         gsub(/^"|"$/, "", val)
         if (val ~ /^-?[0-9]+([.][0-9]+)?$/) {
            sum += val
            count++
         }
      }
      END {
         printf "%s\t%.12g\t%d\n", row_num, sum + 0, count + 0
      }
   ' "$resolved"
done > "$RUNTIME_TSV"

awk -F',' \
  -v summary_file="$TMP_DIR/summary.txt" \
  -v state_file="$TMP_DIR/states.txt" \
  -v state_totals_file="$TMP_DIR/state_totals.txt" \
  -v scenario_file="$TMP_DIR/scenarios.txt" \
  -v scenario_totals_file="$TMP_DIR/scenario_totals.txt" \
  -v runtime_file="$RUNTIME_TSV" \
'
function unquote(x) {
   gsub(/\r$/, "", x)
   gsub(/^"/, "", x)
   gsub(/"$/, "", x)
   gsub(/""/, "\"", x)
   return x
}

function mean_or_na(sum, count) {
   if (count <= 0) return "NA"
   return sprintf("%.1f", sum / count)
}

BEGIN {
   while ((getline line < runtime_file) > 0) {
      split(line, fields, "\t")
      runtime_sum[fields[1]] = fields[2] + 0
      runtime_count[fields[1]] = fields[3] + 0
   }
   close(runtime_file)
}

NR == 1 {
   for (i = 1; i <= NF; i++) {
      name = unquote($i)
      col[name] = i
   }
   next
}

{
   row_num = NR - 1
   state = unquote($col["state"])
   scenario = unquote($col["scenario"])
   finished = $col["finished"] + 0
   missing = $col["missing"] + 0

   rt_sum = runtime_sum[row_num]
   rt_count = runtime_count[row_num]

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
' "$STATUS_ABS"

cat "$TMP_DIR/summary.txt"
echo "STATES"
sort "$TMP_DIR/states.txt"
cat "$TMP_DIR/state_totals.txt"
echo "SCENARIOS"
sort "$TMP_DIR/scenarios.txt"
cat "$TMP_DIR/scenario_totals.txt"
