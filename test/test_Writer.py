import csv
import json

from src.baseclasses.Group import Compartments, RiskGroup, VaccineGroup
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.baseclasses.Writer import Writer


def make_network():
    network = Network(["S", "E", "I", "R"])

    first = PopulationCompartments([100, 50], [0.0, 0.2])
    first.compartment_data[
        0, RiskGroup.L.value, VaccineGroup.U.value, Compartments.S.value
    ] -= 10
    first.compartment_data[
        0, RiskGroup.L.value, VaccineGroup.U.value, Compartments.E.value
    ] += 6
    first.compartment_data[
        0, RiskGroup.L.value, VaccineGroup.U.value, Compartments.I.value
    ] += 4

    second = PopulationCompartments([80, 20], [0.25, 0.0])
    second.compartment_data[
        0, RiskGroup.H.value, VaccineGroup.U.value, Compartments.S.value
    ] -= 5
    second.compartment_data[
        0, RiskGroup.H.value, VaccineGroup.U.value, Compartments.R.value
    ] += 5

    network._add_node(Node(0, "001", 1, first))
    network._add_node(Node(1, "003", 3, second))
    return network


def test_single_realization_writes_daily_json_with_network_totals(tmp_path):
    network = make_network()
    writer = Writer(
        output_dir_path=str(tmp_path),
        realization_index=7,
        total_sims=1,
        batch_num="batch",
    )

    assert writer.output_dir == str(tmp_path / "output_sim7")
    assert "output.json" in str(writer)

    writer.write_json(0, network)
    writer.write_json(1, network)

    day_zero_path = tmp_path / "output_sim7" / "output_0.json"
    day_one_path = tmp_path / "output_sim7" / "output_1.json"
    assert day_zero_path.exists()
    assert day_one_path.exists()
    assert not (tmp_path / "output_sim7" / "output.json").exists()

    output = json.loads(day_zero_path.read_text())
    assert output["day"] == 0
    assert output["reports"] == []
    assert [node["fips_id"] for node in output["data"]] == ["1", "3"]
    assert output["total_summary"] == {
        "S": 235.0,
        "E": 6.0,
        "I": 4.0,
        "R": 5.0,
    }
    assert output["data"][0]["compartment_summary_percent"]["E"] == 4.0


def test_multiple_realizations_append_node_and_network_csv_rows(tmp_path):
    network = make_network()

    for sim_id in (7, 8):
        writer = Writer(
            output_dir_path=str(tmp_path),
            realization_index=sim_id,
            total_sims=2,
            batch_num="42",
        )
        assert str(writer) == f"Writer class: Output directory {tmp_path}"
        writer.write_csv(0, network)

    node_path = tmp_path / "node_1_batch-42.csv"
    with node_path.open(newline="") as handle:
        node_rows = list(csv.DictReader(handle))

    assert [row["sim_id"] for row in node_rows] == ["7", "8"]
    assert [row["day"] for row in node_rows] == ["0", "0"]
    assert all(row["S"] == "140.0" for row in node_rows)
    assert all(row["E"] == "6.0" for row in node_rows)
    assert all(row["I"] == "4.0" for row in node_rows)
    assert node_rows[0]["E_L_U_age0"] == "6.0"
    assert node_rows[0]["S_H_U_age1"] == "10.0"

    network_path = tmp_path / "network_batch-42.csv"
    with network_path.open(newline="") as handle:
        network_rows = list(csv.DictReader(handle))

    assert network_rows == [
        {
            "sim_id": "7",
            "day": "0",
            "S": "235.0",
            "E": "6.0",
            "I": "4.0",
            "R": "5.0",
        },
        {
            "sim_id": "8",
            "day": "0",
            "S": "235.0",
            "E": "6.0",
            "I": "4.0",
            "R": "5.0",
        },
    ]


def test_multiple_days_append_without_repeating_csv_header(tmp_path):
    writer = Writer(
        output_dir_path=str(tmp_path),
        realization_index=3,
        total_sims=5,
        batch_num="99",
    )
    network = make_network()

    writer.write_csv(0, network)
    writer.write_csv(1, network)

    network_lines = (tmp_path / "network_batch-99.csv").read_text().splitlines()
    node_lines = (tmp_path / "node_1_batch-99.csv").read_text().splitlines()
    assert len(network_lines) == 3
    assert len(node_lines) == 3
    assert sum(line.startswith("sim_id,day") for line in network_lines) == 1
    assert sum(line.startswith("sim_id,day") for line in node_lines) == 1
