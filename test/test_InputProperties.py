import json
import pytest

from src.baseclasses.InputProperties import InputProperties

FILENAME = './test/data/texas/INPUT.json'
IP = InputProperties(FILENAME)

with open(FILENAME, 'r') as f:
    DATA = json.load(f)


def test_InputProperties():
    assert IP.number_of_realizations       == int(DATA['panflu']['number_of_realizations'])
    assert IP.output_data_file             == DATA['panflu']['output']
    assert IP.public_health_announcements  == DATA['panflu']['public_health_announcements']
    assert IP.vaccine_pro_rata             == DATA['panflu']['pro_rata']
    assert IP.vaccine_universal            == DATA['panflu']['universal']
    assert IP.initial                      == DATA['panflu']['initial']
    assert IP.vaccines                     == DATA['panflu']['vaccines']


def test_InputProperties_params():
    assert IP.R0                           == float(DATA['panflu']['params']['R0'])
    assert IP.beta_scale                   == float(DATA['panflu']['params']['beta_scale'])
    assert IP.tau                          == float(DATA['panflu']['params']['tau'])
    assert IP.kappa                        == float(DATA['panflu']['params']['kappa'])
    assert IP.gamma                        == float(DATA['panflu']['params']['gamma'])
    assert IP.chi                          == float(DATA['panflu']['params']['chi'])
    assert IP.rho                          == float(DATA['panflu']['params']['rho'])
    assert IP.vaccine_wastage_factor       == float(DATA['panflu']['params']['vaccine_wastage_factor'])
    assert IP.antiviral_effectiveness      == float(DATA['panflu']['params']['antiviral_effectiveness'])
    assert IP.antiviral_wastage_factor     == float(DATA['panflu']['params']['antiviral_wastage_factor'])
    assert IP.nu_high                      == DATA['panflu']['params']['nu_high']


def test_InputProperties_data():
    assert IP.population_data_file         == DATA['panflu']['data']['population']
    assert IP.contact_data_file            == DATA['panflu']['data']['contact']
    assert IP.flow_data_file               == DATA['panflu']['data']['flow']
    assert IP.high_risk_ratios_file        == DATA['panflu']['data']['high_risk_ratios']
    assert IP.flow_reduction_file == DATA['panflu']['data']['flow_reduction']
    assert IP.vaccine_effectiveness_file   == DATA['panflu']['data']['vaccine_effectiveness']
    assert IP.vaccine_adherence_file       == DATA['panflu']['data']['vaccine_adherence']
    assert IP.relative_susceptibility_file == DATA['panflu']['data']['relative_susceptibility']
    assert IP.nu_value_matrix_file == DATA['panflu']['data']['nu_value_matrix']
