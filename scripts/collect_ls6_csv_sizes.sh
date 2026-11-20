#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h || $# -gt 1 ]]; then
  cat <<'USAGE'
Usage: bash scripts/collect_ls6_csv_sizes.sh [LS6_RmSweep_TEST] > ls6_csv_sizes.csv

Run on LS6 where the original outputs are stored. Requires Python 3.
Reads metadata_master.csv and reports original CSV sizes in bytes, one row
per scenario_hash and batch_num. Incomplete rows have a blank total and an
explanation in csv_size_status. The script exits 1 if any batch is incomplete.
USAGE
  [[ $# -le 1 ]]
  exit
fi

# Use Python's CSV reader because the master contains quoted JSON with commas.
exec python3 - "${1:-LS6_RmSweep_TEST}" <<'PYTHON'
import csv
import os
import sys
from pathlib import Path, PurePosixPath


def scenario_label(row):
    interventions = []
    for name, column in (("VACCINE", "vaccine_used"),
                         ("ANTIVIRAL", "antiviral_used"), ("NPI", "npi_used")):
        flag = row[column].strip().upper()
        if flag not in {"TRUE", "FALSE"}:
            raise ValueError(f"Invalid {column}: {row[column]!r}")
        if flag == "TRUE":
            interventions.append(name)
    if len(interventions) == 3:
        return "ALL_INTERVENTIONS"
    return "+".join(interventions) or "NONE"


def source_directory(row):
    recorded = PurePosixPath(row["file_path"])
    state_hash = f'{row["geo_region"]}_{row["scenario_hash"]}'
    metadata_name = f'metadata_batch-{row["batch_num"]}.json'
    if recorded.parent.name != state_hash or recorded.name != metadata_name:
        raise ValueError(f"Metadata path does not match batch key: {recorded}")

    # Rebase paths recorded on scratch onto the sweep root passed to the script.
    for index, part in enumerate(recorded.parts[:-2]):
        if part in {"TACC_FILES", "Rm_search"} and ".." not in recorded.parts[index:]:
            return Path(*recorded.parts[index:-1])
    raise ValueError(f"Expected a TACC_FILES or Rm_search metadata path: {recorded}")


def measure_csvs(directory, row):
    suffix = f'_batch-{row["batch_num"]}.csv'
    node_sizes = []
    shard_count = 0
    other_sizes = {}
    with os.scandir(directory) as entries:
        for entry in entries:
            if not entry.name.endswith(suffix) or not entry.is_file():
                continue
            prefix = entry.name[:-len(suffix)]
            if prefix.startswith("node_"):
                node_sizes.append(entry.stat().st_size)
                shard_count += prefix.startswith("node_realization-")
            elif prefix in {"network", "simulation_times"}:
                other_sizes[prefix] = entry.stat().st_size

    missing = {"network", "simulation_times"} - other_sizes.keys()
    if missing:
        raise ValueError(f"Missing CSVs: {', '.join(sorted(missing))}")
    if shard_count and shard_count != len(node_sizes):
        raise ValueError("Both per-realization and per-county node CSVs found for the batch")
    expected_column = "complete_realization_count" if shard_count else "geo_node_count"
    expected = int(row[expected_column])
    if expected < 1 or len(node_sizes) != expected:
        raise ValueError(f"Found {len(node_sizes)} node CSVs, expected {expected}")

    network = other_sizes["network"]
    nodes = sum(node_sizes)
    times = other_sizes["simulation_times"]
    return network, nodes, times, len(node_sizes), network + nodes + times


def main(root):
    key_columns = ("scenario_hash", "batch_num")
    size_columns = ("network_csv_bytes", "nodes_csv_bytes", "sim_times_csv_bytes",
                    "node_csv_count", "total_csv_bytes")
    with (root / "metadata_master.csv").open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        required = {*key_columns, "geo_region", "file_path", "vaccine_used", "antiviral_used",
                    "npi_used", "geo_node_count", "complete_realization_count"}
        missing = required - set(reader.fieldnames or ())
        if missing:
            raise ValueError(f"Missing metadata columns: {', '.join(sorted(missing))}")
        rows = list(reader)

    keys = [tuple(row[column] for column in key_columns) for row in rows]
    if not keys or any(not all(key) for key in keys) or len(set(keys)) != len(keys):
        raise ValueError("Expected at least one batch and unique, nonempty metadata batch keys")

    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(("geo_region", "scenario", *key_columns, "source_directory",
                     *size_columns, "csv_size_status"))
    incomplete = 0
    for row, key in zip(rows, keys):
        label = None
        relative = None
        try:
            label = scenario_label(row)
            relative = source_directory(row)
            sizes = measure_csvs(root / relative, row)
            status = "ok"
        except (OSError, ValueError) as error:
            sizes = (None,) * len(size_columns)
            status = str(error)
            incomplete += 1
        writer.writerow((row["geo_region"], label, *key, relative, *sizes, status))

    print(f"Measured {len(rows) - incomplete}/{len(rows)} batches; {incomplete} incomplete.",
          file=sys.stderr)
    return int(incomplete > 0)


try:
    sys.exit(main(Path(sys.argv[1])))
except (OSError, ValueError, csv.Error) as error:
    sys.exit(f"Could not read batch metadata: {error}")
PYTHON
