import csv
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from utils.Execution import choose_workers, parse_execution


@pytest.fixture
def cpu_environment(monkeypatch):
    for key in ('SLURM_JOB_ID', 'SLURM_CPUS_PER_TASK', 'SIMULATOR_CPUS_PER_TASK'):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(os, 'cpu_count', lambda: 128)
    monkeypatch.setattr(os, 'sched_getaffinity', lambda pid: set(range(128)), raising=False)


def test_worker_budget_is_per_command(cpu_environment, monkeypatch):
    auto = parse_execution({'mode': 'parallel'})
    assert choose_workers(auto, 1000) == 4
    assert choose_workers(auto, 2) == 2
    monkeypatch.setenv('SLURM_JOB_ID', '123')
    assert choose_workers(auto, 1000) == 1
    monkeypatch.setenv('SLURM_CPUS_PER_TASK', '32')
    assert choose_workers(auto, 1000) == 4
    monkeypatch.setenv('SIMULATOR_CPUS_PER_TASK', '2')
    assert choose_workers(parse_execution({'mode': 'parallel', 'workers': 32}), 1000) == 2
    assert choose_workers(parse_execution({}), 1000) == 1


@pytest.mark.parametrize('workers', [2, '2', ' 2 '])
def test_integer_workers_normalized(workers, cpu_environment):
    execution = parse_execution({'mode': 'parallel', 'workers': workers})
    assert execution == {'mode': 'parallel', 'workers': 2}
    assert type(execution['workers']) is int
    assert choose_workers(execution, 1000) == 2


@pytest.mark.parametrize('value', [True, {'mode': 'threaded'}, {'workers': 0},
                                       {'workers': True}, {'workers': 1.5}, {'worker': 2},
                                       {'workers': '0'}, {'workers': '-2'}, {'workers': '1.5'},
                                       {'workers': 'invalid'}, {'workers': ''}, {'workers': None}])
def test_invalid_execution_rejected(value):
    with pytest.raises(ValueError):
        parse_execution(value)


def _rows(paths):
    rows = []
    for path in paths:
        with path.open(newline='') as handle:
            rows.extend(csv.DictReader(handle))
    return sorted(rows, key=lambda row: (int(row['sim_id']), int(row.get('day', 0)), row.get('fips_id', '')))


def test_spawned_realizations_match_serial_and_keep_hash(tmp_path):
    """Exercise real stochastic/intervention models, spawn, CSVs and metadata.

    Two counties and five days keep this small; three realizations exercise reuse
    of a worker with two workers and serial isolation of mutable stockpiles.
    """
    root = Path(__file__).resolve().parents[1]
    config = json.loads((root / 'data/INPUT_FILE_TEMPLATES/INPUT_SEIHRD-STOCH_STATE_ALL_INTERVENTIONS_H3N2.json').read_text())
    population = tmp_path / 'population.csv'
    population.write_text('\n'.join((root / 'data/Texas/county_pop_by_age_Texas_2020-2024ACS.csv').read_text().splitlines()[:3]) + '\n')
    flow = tmp_path / 'flow.csv'
    flow.write_text('0,0.1\n0.1,0\n')
    config['data'] = {
        'population': str(population), 'flow': str(flow),
        'contact': str(root / 'data/Texas/contact_matrix_Texas_Mistry2021_all.csv'),
        'high_risk_ratios': str(root / 'data/Texas/state_Texas_high-risk-ratios-flu-only.csv'),
    }
    config['initial_exposed'] = [{'county': '48001', 'infected': '50', 'age_group': '0'}]
    config['realization_range'] = [0, 2]
    config['batch_num'] = 'test'
    config['metadata_tags'] = {}
    config['non_pharma_interventions'] = []
    for treatment in ('antiviral_model', 'vaccine_model'):
        key = 'antiviral_stockpile' if treatment == 'antiviral_model' else 'vaccine_stockpile'
        config[treatment]['parameters'][key] = [{'day': '0', 'amount': '100'}]
    config['vaccine_model']['parameters']['vaccine_eff_lag_days'] = 0

    # Fixed base seed only in this test harness, without adding seed policy to MVP.
    runner = tmp_path / 'runner.py'
    runner.write_text('import simulator\nif __name__ == "__main__":\n    simulator.token_bytes = lambda n: bytes([7]) * n\n    simulator.main()\n')
    env = {**os.environ, 'PYTHONPATH': str(root / 'src'), 'SIMULATOR_CPUS_PER_TASK': '2',
           'MPLCONFIGDIR': str(tmp_path / 'matplotlib')}
    outputs = []
    for label, execution in [('serial', {}), ('parallel', {'mode': 'parallel', 'workers': '2'}),
                             ('parallel_one', {'mode': 'parallel', 'workers': 1})]:
        output = tmp_path / label
        output.mkdir()
        config['output_dir_path'] = str(output)
        config['execution'] = execution
        input_file = tmp_path / f'{label}.json'
        input_file.write_text(json.dumps(config))
        completed = subprocess.run([sys.executable, str(runner), '-i', str(input_file), '-d', '5'],
                                   cwd=root, env=env, capture_output=True, text=True, timeout=90)
        assert completed.returncode == 0, completed.stderr
        outputs.append(output)
        assert len(_rows(output.glob('simulation_times*.csv'))) == 3
        assert not list(output.glob('.realizations*'))
        if label != 'serial':
            assert len(list(output.glob('node_*.csv'))) == 3
        metadata = json.loads(next(output.glob('metadata_batch-*.json')).read_text())
        if label == 'serial':
            scenario_hash = metadata['scenario_hash']
        else:
            assert metadata['scenario_hash'] == scenario_hash
            assert metadata['execution']['resolved_workers'] == int(execution['workers'])

    for pattern in ('node_*.csv', 'network_batch-*.csv'):
        reference = _rows(outputs[0].glob(pattern))
        assert len(reference) == (36 if pattern.startswith('node_') else 18)
        for output in outputs[1:]:
            assert _rows(output.glob(pattern)) == reference

    # A repeat launch must fail before modifying completed output or metadata.
    metadata_path = next(outputs[-1].glob('metadata_batch-*.json'))
    original_metadata = metadata_path.read_bytes()
    repeated = subprocess.run([sys.executable, str(runner), '-i', str(input_file), '-d', '5'],
                              cwd=root, env=env, capture_output=True, text=True, timeout=90)
    assert repeated.returncode != 0
    assert 'This batch already has output' in repeated.stderr
    assert metadata_path.read_bytes() == original_metadata
