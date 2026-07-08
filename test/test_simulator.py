from types import SimpleNamespace

import pytest

from src import simulator


class Recorder:
    def __init__(self):
        self.calls = []

    def record(self, name):
        def method(*args, **kwargs):
            self.calls.append((name, args, kwargs))
        return method


class FakeDay:
    def __init__(self, days, snapshots):
        self.day = days
        self._snapshots = iter(snapshots)
        self.plotted = []

    def snapshot(self, network):
        return next(self._snapshots)

    def plot(self, output_dir):
        self.plotted.append(output_dir)


def make_run_objects(total_sims=1):
    recorder = Recorder()
    network = SimpleNamespace(
        nodes=[SimpleNamespace(node_id=0), SimpleNamespace(node_id=1)],
        comp_index={"E": 0, "I": 1},
    )
    vaccine_model = SimpleNamespace(
        distribute_vaccines_to_nodes=recorder.record("vaccine_nodes"),
        distribute_vaccines_to_population=recorder.record("vaccine_population"),
    )
    antiviral_model = SimpleNamespace(
        distribute_antivirals_to_nodes=recorder.record("antiviral_nodes"),
        distribute_antivirals_to_population=recorder.record("antiviral_population"),
    )
    disease_model = SimpleNamespace(simulate=recorder.record("simulate"))
    travel_model = SimpleNamespace(
        transmit_dict={"I": 1.0},
        travel=recorder.record("travel"),
    )
    writer = SimpleNamespace(
        total_sims=total_sims,
        output_dir="output",
        write_json=recorder.record("write_json"),
        write_csv=recorder.record("write_csv"),
    )
    return recorder, network, vaccine_model, antiviral_model, disease_model, travel_model, writer


def test_parse_args_uses_defaults_and_user_values():
    defaults = simulator.parse_args(["-i", "input.json"])
    assert defaults.days == 365
    assert defaults.loglevel == "WARNING"

    custom = simulator.parse_args(
        ["-i", "scenario.json", "-d", "14", "-l", "DEBUG"]
    )
    assert custom.input_filename == "scenario.json"
    assert custom.days == 14
    assert custom.loglevel == "DEBUG"


def test_run_orders_daily_work_and_stops_after_infections_clear():
    (
        recorder,
        network,
        vaccine_model,
        antiviral_model,
        disease_model,
        travel_model,
        writer,
    ) = make_run_objects(total_sims=1)
    simulation_days = FakeDay(3, snapshots=[[1.0, 1.0], [2.0, 1.0], [0.0, 0.0]])

    simulator.run(
        simulation_days,
        SimpleNamespace(),
        network,
        antiviral_model,
        vaccine_model,
        disease_model,
        travel_model,
        writer,
    )

    names = [name for name, _, _ in recorder.calls]
    assert names[:6] == [
        "vaccine_nodes",
        "antiviral_nodes",
        "vaccine_population",
        "antiviral_population",
        "vaccine_population",
        "antiviral_population",
    ]
    assert [call[1][0] for call in recorder.calls if call[0] == "write_json"] == [0, 1, 2]
    assert names.count("simulate") == 4
    assert names.count("travel") == 2
    assert simulation_days.plotted == ["output"]


def test_run_writes_csv_for_multiple_realizations_and_completes_all_days():
    (
        recorder,
        network,
        vaccine_model,
        antiviral_model,
        disease_model,
        travel_model,
        writer,
    ) = make_run_objects(total_sims=2)
    simulation_days = FakeDay(2, snapshots=[[1.0, 1.0], [1.0, 1.0], [1.0, 1.0]])

    simulator.run(
        simulation_days,
        SimpleNamespace(),
        network,
        antiviral_model,
        vaccine_model,
        disease_model,
        travel_model,
        writer,
    )

    assert [call[1][0] for call in recorder.calls if call[0] == "write_csv"] == [0, 1, 2]
    assert not [call for call in recorder.calls if call[0] == "write_json"]
    assert simulation_days.plotted == []


def test_run_rejects_missing_infectious_compartment_mapping():
    (
        _,
        network,
        vaccine_model,
        antiviral_model,
        disease_model,
        travel_model,
        writer,
    ) = make_run_objects()
    travel_model.transmit_dict = {"IA": 1.0}
    simulation_days = FakeDay(1, snapshots=[[1.0, 1.0], [1.0, 1.0]])

    with pytest.raises(KeyError, match="IA"):
        simulator.run(
            simulation_days,
            SimpleNamespace(),
            network,
            antiviral_model,
            vaccine_model,
            disease_model,
            travel_model,
            writer,
        )


def test_main_initializes_models_and_records_realization_time(tmp_path, monkeypatch):
    input_path = tmp_path / "input.json"
    input_path.write_text("{}")
    output_path = tmp_path / "generated-output"
    calls = []

    simulation_properties = SimpleNamespace(
        realization_indices=[7],
        batch_num="42",
        population_data_file="population.csv",
        flow_data_file="flow.csv",
        non_pharma_interventions=[],
        antiviral_model=None,
        vaccine_model=None,
        disease_model="seirs-stochastic",
        travel_model="binomial",
        initial=[],
        output_dir_path="GENERATE",
    )
    parameters = SimpleNamespace(
        disease_parameters={"compartments": ["S", "E", "I", "R"]},
        high_risk_ratios=["0.0"],
        number_of_age_groups=1,
    )

    class FakeNetwork:
        def __init__(self, labels):
            self.labels = labels
            self.nodes = [SimpleNamespace(node_id=0)]

        def load_population_file(self, path):
            calls.append(("load_population", path))

        def population_to_nodes(self, ratios):
            calls.append(("population_to_nodes", ratios))

        def get_total_population(self):
            return 100

        def get_number_of_nodes(self):
            return 1

        def add_travel_flow_data(self, flow_data):
            calls.append(("add_flow", flow_data))

    class FakeTravelFlow:
        def __init__(self, node_count):
            self.flow_data = [[0.0]]
            calls.append(("travel_flow_size", node_count))

        def load_travel_flow_file(self, path):
            calls.append(("load_flow", path))

    class FakeNpis:
        def __init__(self, interventions, days, nodes, age_groups):
            calls.append(("npis", interventions, days, nodes, age_groups))

        def pre_process(self, network):
            calls.append(("pre_process", network))

    class FakeTreatmentParent:
        def __init__(self, params):
            self.params = params

        def get_child(self, identity, network):
            return SimpleNamespace(identity=identity)

    disease_model = SimpleNamespace(
        set_initial_conditions=lambda initial, network, vaccine: calls.append(
            ("initial_conditions", initial)
        ),
        set_seed=lambda seed: calls.append(("seed", seed)),
    )

    class FakeDiseaseParent:
        def __init__(self, params, npis, now):
            pass

        def get_child(self, identity):
            calls.append(("disease_child", identity))
            return disease_model

    travel_model = SimpleNamespace(identity="binomial")

    class FakeTravelParent:
        def __init__(self, params):
            pass

        def get_child(self, identity):
            calls.append(("travel_child", identity))
            return travel_model

    class FakeWriter:
        def __init__(self, **kwargs):
            self.kwargs = kwargs
            calls.append(("writer", kwargs))

    monkeypatch.setattr(simulator, "InputProperties", lambda path: simulation_properties)
    monkeypatch.setattr(simulator, "ModelParameters", lambda props: parameters)
    monkeypatch.setattr(simulator, "Network", FakeNetwork)
    monkeypatch.setattr(simulator, "TravelFlow", FakeTravelFlow)
    monkeypatch.setattr(simulator, "NonPharmaInterventions", FakeNpis)
    monkeypatch.setattr(simulator, "Antiviral", FakeTreatmentParent)
    monkeypatch.setattr(simulator, "Vaccination", FakeTreatmentParent)
    monkeypatch.setattr(simulator, "DiseaseModel", FakeDiseaseParent)
    monkeypatch.setattr(simulator, "TravelModel", FakeTravelParent)
    monkeypatch.setattr(simulator, "Writer", FakeWriter)
    monkeypatch.setattr(simulator, "Day", lambda days: SimpleNamespace(day=days))
    monkeypatch.setattr(
        simulator,
        "build_executed_config",
        lambda **kwargs: {"output_dir_path": str(output_path)},
    )
    monkeypatch.setattr(
        simulator,
        "write_metadata_json",
        lambda **kwargs: calls.append(("metadata", kwargs["output_dir"])),
    )
    monkeypatch.setattr(
        simulator,
        "run",
        lambda *args: calls.append(("run", args[-1].kwargs["realization_index"])),
    )
    times = iter([10.0, 12.5])
    monkeypatch.setattr(simulator.time, "perf_counter", lambda: next(times))

    simulator.main(
        SimpleNamespace(
            input_filename=str(input_path),
            days=5,
            loglevel="INFO",
        )
    )

    assert simulation_properties.output_dir_path == str(output_path)
    assert (output_path / "input_batch-42.json").read_text() == "{}"
    assert ("metadata", str(output_path)) in calls
    assert ("run", 7) in calls
    timing_csv = output_path / "simulation_times_batch-42.csv"
    assert timing_csv.read_text().splitlines() == [
        "sim_id,time_seconds",
        "7,2.5",
    ]
