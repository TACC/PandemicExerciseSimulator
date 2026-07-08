import pytest

from src.models.treatments.NonPharmaInterventions import NonPharmaInterventions


def test_overlapping_npis_combine_remaining_transmission():
    npis = [
        {
            "name": "First intervention",
            "day": "0",
            "duration": "1",
            "location": "0",
            "effectiveness": ["0.5"],
        },
        {
            "name": "Second intervention",
            "day": "0",
            "duration": "1",
            "location": "0",
            "effectiveness": ["0.5"],
        },
    ]
    interventions = NonPharmaInterventions(
        npis=npis,
        num_days=1,
        num_locations=1,
        num_age_groups=1,
    )

    interventions.pre_process(network=None)

    assert interventions.schedule[0, 0, 0] == pytest.approx(0.75)
