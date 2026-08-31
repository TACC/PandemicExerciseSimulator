#!/usr/bin/env bash
set -euo pipefail

# Check TACC launcher progress for state_commands.txt outputs.
# Run from STATE_WKLYFIT_TEST/TACC_FILES on TACC:
#   bash ../../scripts/find_missing_state_sims.sh state_commands.txt .
#
# Or from repo root:
#   bash scripts/find_missing_state_sims.sh STATE_WKLYFIT_TEST/TACC_FILES/state_commands.txt STATE_WKLYFIT_TEST/TACC_FILES

COMMAND_FILE="${1:-state_commands.txt}"
SEARCH_ROOT="${2:-.}"
EXPECTED_START="${EXPECTED_START:-0}"
EXPECTED_END="${EXPECTED_END:-99}"
STATUS_CSV="${STATUS_CSV:-state_sim_progress.csv}"
RESUBMIT_FILE="${RESUBMIT_FILE:-state_resubmit_commands.txt}"

EXPECTED_COUNT=$((EXPECTED_END - EXPECTED_START + 1))

if [[ ! -f "$COMMAND_FILE" ]]; then
   echo "ERROR: command file not found: $COMMAND_FILE" >&2
   exit 1
fi

if [[ ! -d "$SEARCH_ROOT" ]]; then
   echo "ERROR: search root not found: $SEARCH_ROOT" >&2
   exit 1
fi

input_from_cmd() {
   sed -nE "s/.*[[:space:]]-i[[:space:]]+'?([^'[:space:]]+)'?.*/\1/p" <<< "$1"
}

state_from_input() {
   local base stem
   base="$(basename "$1")"
   stem="${base%.json}"
   sed -E 's/^INPUT_(.*)_(NONE|VACCINE|ANTIVIRAL|NPI|ALL_INTERVENTIONS)$/\1/' <<< "$stem"
}

scenario_from_input() {
   local base stem
   base="$(basename "$1")"
   stem="${base%.json}"
   sed -E 's/^INPUT_.*_(NONE|VACCINE|ANTIVIRAL|NPI|ALL_INTERVENTIONS)$/\1/' <<< "$stem"
}

csv_quote() {
   local s="${1//\"/\"\"}"
   printf '"%s"' "$s"
}

latest_timing_file() {
   local dir="$1"
   find "$dir" -maxdepth 1 -type f -name 'simulation_times_batch-*.csv' -print0 \
      | xargs -0 ls -t 2>/dev/null \
      | head -n 1
}

count_finished_ids() {
   local timing_file="$1"
   awk -F',' -v start="$EXPECTED_START" -v end="$EXPECTED_END" '
      NR == 1 {
         for (i = 1; i <= NF; i++) {
            gsub(/^"|"$/, "", $i)
            if ($i == "sim_id") sim_col = i
         }
         next
      }
      sim_col {
         val = $sim_col
         gsub(/^"|"$/, "", val)
         if (val ~ /^[0-9]+$/ && val >= start && val <= end) seen[val] = 1
      }
      END {
         for (id in seen) count++
         print count + 0
      }
   ' "$timing_file"
}

last_finished_id() {
   local timing_file="$1"
   awk -F',' -v start="$EXPECTED_START" -v end="$EXPECTED_END" '
      NR == 1 {
         for (i = 1; i <= NF; i++) {
            gsub(/^"|"$/, "", $i)
            if ($i == "sim_id") sim_col = i
         }
         next
      }
      sim_col {
         val = $sim_col
         gsub(/^"|"$/, "", val)
         if (val ~ /^[0-9]+$/ && val >= start && val <= end) last = val
      }
      END {
         if (last == "") print "NA"; else print last
      }
   ' "$timing_file"
}

missing_ids() {
   local timing_file="$1"
   awk -F',' -v start="$EXPECTED_START" -v end="$EXPECTED_END" '
      NR == 1 {
         for (i = 1; i <= NF; i++) {
            gsub(/^"|"$/, "", $i)
            if ($i == "sim_id") sim_col = i
         }
         next
      }
      sim_col {
         val = $sim_col
         gsub(/^"|"$/, "", val)
         if (val ~ /^[0-9]+$/ && val >= start && val <= end) seen[val] = 1
      }
      END {
         sep = ""
         for (i = start; i <= end; i++) {
            if (!(i in seen)) {
               printf "%s%s", sep, i
               sep = ";"
            }
         }
         printf "\n"
      }
   ' "$timing_file"
}

find_output_dir() {
   local state="$1"
   local scenario="$2"
   local input_base="$3"
   local dir meta

   for dir in "$SEARCH_ROOT"/"${state}_"*; do
      [[ -d "$dir" ]] || continue

      for meta in "$dir"/metadata_batch-*.json; do
         [[ -f "$meta" ]] || continue
         if grep -q "\"input_filename\".*${input_base}" "$meta"; then
            printf '%s\n' "$dir"
            return 0
         fi
         if grep -q "\"state_dir\"[[:space:]]*:[[:space:]]*\"${state}\"" "$meta" \
            && grep -q "\"scenario_label\"[[:space:]]*:[[:space:]]*\"${scenario}\"" "$meta"; then
            printf '%s\n' "$dir"
            return 0
         fi
      done
   done

   return 1
}

printf 'state,scenario,input_file,output_dir,timing_file,finished,missing,last_sim_id,percent_complete,needs_resubmit,missing_ids\n' > "$STATUS_CSV"
: > "$RESUBMIT_FILE"

total=0
complete=0
partial=0
not_started=0

while IFS= read -r cmd; do
   [[ -z "${cmd//[[:space:]]/}" ]] && continue
   [[ "$cmd" =~ ^[[:space:]]*# ]] && continue

   total=$((total + 1))
   input_file="$(input_from_cmd "$cmd")"

   if [[ -z "$input_file" ]]; then
      echo "WARN: could not parse -i input from command $total: $cmd" >&2
      echo "$cmd" >> "$RESUBMIT_FILE"
      continue
   fi

   input_base="$(basename "$input_file")"
   state="$(state_from_input "$input_file")"
   scenario="$(scenario_from_input "$input_file")"
   output_dir="$(find_output_dir "$state" "$scenario" "$input_base" || true)"

   finished=0
   missing="$EXPECTED_COUNT"
   last_id="NA"
   timing_file="NA"
   ids=""
   needs=1

   if [[ -n "$output_dir" ]]; then
      timing_file="$(latest_timing_file "$output_dir" || true)"
      if [[ -n "$timing_file" && -f "$timing_file" ]]; then
         finished="$(count_finished_ids "$timing_file")"
         last_id="$(last_finished_id "$timing_file")"
         ids="$(missing_ids "$timing_file")"
      fi
   else
      output_dir="NA"
      ids="$(seq -s ';' "$EXPECTED_START" "$EXPECTED_END")"
   fi

   missing=$((EXPECTED_COUNT - finished))
   if [[ "$missing" -le 0 ]]; then
      needs=0
      missing=0
      complete=$((complete + 1))
   else
      echo "$cmd" >> "$RESUBMIT_FILE"
      if [[ "$finished" -gt 0 ]]; then
         partial=$((partial + 1))
      else
         not_started=$((not_started + 1))
      fi
   fi

   percent="$(awk -v f="$finished" -v e="$EXPECTED_COUNT" 'BEGIN { printf "%.1f", 100 * f / e }')"

   {
      csv_quote "$state"; printf ','
      csv_quote "$scenario"; printf ','
      csv_quote "$input_file"; printf ','
      csv_quote "$output_dir"; printf ','
      csv_quote "$timing_file"; printf ','
      printf '%s,%s,' "$finished" "$missing"
      csv_quote "$last_id"; printf ','
      printf '%s,%s,' "$percent" "$needs"
      csv_quote "$ids"; printf '\n'
   } >> "$STATUS_CSV"
done < "$COMMAND_FILE"

echo "Checked commands: $total"
echo "Complete: $complete"
echo "Partial: $partial"
echo "Not started: $not_started"
echo "Wrote: $STATUS_CSV"
echo "Wrote: $RESUBMIT_FILE"
