#!/usr/bin/env python3
import sys, os, csv, json
from typing import Any, Dict, List, Type
from .Network import Network

import logging
logger = logging.getLogger(__name__)

def _write_dict_row(path: str, row: Dict[str, Any]) -> None:
    """Append one CSV row; write header if file is new/empty."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_header = (not os.path.exists(path)) or (os.path.getsize(path) == 0)
    with open(path, "a", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=list(row.keys()))
        if write_header:
            writer.writeheader()
        writer.writerow(row)

def _flatten_subgroups(comp_sub: Dict[str, Any], comp_order: List[str]) -> Dict[str, float]:
    """
    comp_sub: {comp -> {risk -> {vax -> [ages...]}}}
    Returns flat dict with keys like: 'S_L_V_age0'
    Deterministic column order: comp_order, then sorted risk, then sorted vax, then age index.
    """
    return {
        f"{comp}_{risk}_{vax}_age{idx}": float(val)
        for comp in comp_order
        for risk in sorted(comp_sub.get(comp, {}).keys())
        for vax in sorted(comp_sub[comp][risk].keys())
        for idx, val in enumerate(comp_sub[comp][risk][vax])
    }


class Writer:

    def __init__(self, output_dir_path:str = 'output', realization_index:int=0,
                 total_sims:int=1, batch_num:int=0):
        self.sim_id = realization_index
        self.total_sims = total_sims
        self.batch_num = batch_num
        if self.total_sims == 1:
            self.output_dir = os.path.join(output_dir_path, f"output_sim{realization_index}")
            os.makedirs(self.output_dir, exist_ok=True)

            filename = 'output.json'
            self.output_filename = os.path.join(self.output_dir, filename)
            try:
                with open(self.output_filename, 'w') as o:
                    try:
                        o.write('')
                    except (IOError, OSError) as e:
                        raise Exception(f'Error writing to {self.output_filename}') from e
                        sys.exit(1)
                os.remove(self.output_filename)
            except (FileNotFoundError, PermissionError, OSError) as e:
                raise Exception(f'Error opening {self.output_filename}') from e
                sys.exit(1)
            logger.info(f'instantiated Writer object with output file {self.output_filename}')
        else:
            self.output_dir = output_dir_path
            logger.info(f'instantiated Writer object to output dir {self.output_dir}')

        return


    def __str__(self) -> str:
        if self.total_sims == 1:
            return f'Writer class: Output file handle to {self.output_filename}'
        return f'Writer class: Output directory {self.output_dir}'


    def write_json(self, day:int, network:Type[Network]):
        """
        Write output of network to JSON file

        Args:
            day (int): simulation day
            network (Network): Network object with list of nodes
        """
        # TODO collect daily reports of important events for the output, perhaps in the Day object
        # TODO Vaccines wasted/decayed or remaining in stockpile also good for report
        data = {'day': day, 'reports': [], 'data': [], 'total_summary': {}}
        for node in network.nodes:
            nd = node.return_dict()  # includes named compartment_summary
            data['data'].append(nd)
            for c, v in nd['compartment_summary'].items():
                data['total_summary'][c] = float(data['total_summary'].get(c, 0.0) + float(v))

        with open(f'{self.output_filename[:-5]}_{day}.json', 'w') as o:
            o.write(json.dumps(data, indent=2))
        return


    def write_csv(self, day: int, network: Type["Network"]) -> None:
        # Initialize for network totals
        first_nd = network.nodes[0].return_dict()
        comp_order = list(first_nd["compartment_summary"].keys())
        totals = {c: 0.0 for c in comp_order}

        # ---- one pass over nodes: write node rows + accumulate totals ----
        for node in network.nodes:
            nd = node.return_dict()
            fips = str(nd.get("fips_id", "UNKNOWN"))

            base = {
                "sim_id": self.sim_id,
                "day": day,
                "node_index": nd.get("node_index"),
                "node_id": nd.get("node_id"),
                "fips_id": nd.get("fips_id"),
            }

            # Compartment totals for this node (dict comp -> float)
            comp_vals = {c: float(nd["compartment_summary"].get(c, 0.0)) for c in comp_order}
            for c, v in comp_vals.items():
                totals[c] += v

            # Subgroups flattened via a compact comprehension
            sub_vals = _flatten_subgroups(nd.get("compartment_subgroups", {}), comp_order)

            # Stable insertion order: base → comp totals → subgroup columns
            node_row = {**base, **comp_vals, **sub_vals}
            self._write_row(os.path.join(self.output_dir, f"node_{fips}_batch-{self.batch_num}.csv"), node_row)

        # ---- write single network row ----
        network_row = {"sim_id": self.sim_id, "day": day, **totals}
        self._write_row(os.path.join(self.output_dir, f"network_batch-{self.batch_num}.csv"), network_row)
        return

    def _write_row(self, path, row):
        _write_dict_row(path, row)


class RealizationWriter(Writer):
    """Two exclusively owned, buffered files; no daily opens or shared appends.

    Files live in a staging directory until the parent accepts the result.
    """
    def __init__(self, output_dir_path, realization_index, total_sims, batch_num):
        from pathlib import Path

        self.sim_id = realization_index
        self.total_sims = total_sims
        self.batch_num = batch_num
        self.output_dir = str(Path(output_dir_path) / f'.realizations_batch-{batch_num}' / f'sim-{realization_index}')
        Path(self.output_dir).mkdir(parents=True, exist_ok=False)
        self._handles = {}
        self._writers = {}

    def _write_row(self, path, row):
        name = 'nodes.csv' if os.path.basename(path).startswith('node_') else 'network.csv'
        if name not in self._handles:
            handle = open(os.path.join(self.output_dir, name), 'x', newline='', buffering=1024 * 1024)
            self._handles[name] = handle
            self._writers[name] = csv.DictWriter(handle, fieldnames=list(row))
            self._writers[name].writeheader()
        self._writers[name].writerow(row)

    def close(self):
        for handle in self._handles.values():
            handle.close()
