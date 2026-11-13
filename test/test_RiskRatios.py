import numpy as np
import pandas as pd
import pytest

from utils.RiskRatios import parse_high_risk_ratios
from src.baseclasses.Network import Network


def test_county_risk_matches_fips_and_age_labels_without_mutating_input():
    lines = ['fips,5-17,0-4', '01003,.8,.6', '01001,.3,.1']
    result = parse_high_risk_ratios(lines, [1001, 1003], ['0-4', '5-17'])
    np.testing.assert_allclose(result, [[.1, .3], [.6, .8]])
    assert len(lines) == 3
    network = Network(['S', 'E', 'I', 'R'])
    network.df_county_age_matrix = pd.DataFrame({'fips': [1001,1003], '0-4': [100,300], '5-17': [200,400]})
    network.population_to_nodes(lines)
    np.testing.assert_allclose(network.nodes[0].compartments.compartment_data[:, 1, :, :].sum(axis=(1,2)), [10,60])
    np.testing.assert_allclose(network.nodes[1].compartments.compartment_data[:, 1, :, :].sum(axis=(1,2)), [180,320])


@pytest.mark.parametrize('lines,match', [
    (['fips,0-4', '01001,.2'], 'Missing county'),
    (['fips,0-4', '01001,.2', '01001,.3'], 'Duplicate county'),
    (['fips,0-4', '01003,NaN'], 'finite fractions'),
    (['fips,0-4', '01003,1.1'], 'finite fractions'),
    (['fips,5-17', '01003,.2'], 'age labels'),
])
def test_invalid_county_risk_fails_instead_of_misassigning(lines, match):
    with pytest.raises(ValueError, match=match):
        parse_high_risk_ratios(lines, [1003], ['0-4'])


def test_legacy_state_risk_vector_remains_supported():
    np.testing.assert_allclose(parse_high_risk_ratios(['.1', '.2'], [1001,1003], ['0-4','5-17']), [[.1,.2],[.1,.2]])
