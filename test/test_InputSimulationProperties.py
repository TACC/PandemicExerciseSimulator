import json
import pytest

from src.baseclasses.InputSimulationProperties import InputSimulationProperties

FILENAME = './test/data/texas/3D_Fast_Mild_P0-2009_PR-children_Tx-high-risk_Vacc-2009.json'
ISP = InputSimulationProperties(FILENAME)

with open(FILENAME, 'r') as f:
    DATA = json.load(f)

def test_InputSimulationProperties():
    assert ISP.R0                          == float(DATA['panflu']['params']['R0'])
    assert ISP.beta_scale                  == float(DATA['panflu']['params']['beta_scale'])
    assert ISP.tau                         == float(DATA['panflu']['params']['tau'])
    assert ISP.kappa                       == float(DATA['panflu']['params']['kappa'])
    assert ISP.gamma                       == float(DATA['panflu']['params']['gamma'])
    assert ISP.chi                         == float(DATA['panflu']['params']['chi'])
    assert ISP.nu_high                     == DATA['panflu']['params']['nu_high']
    assert ISP.number_of_realizations      == int(DATA['panflu']['number_of_realizations'])
    assert ISP.population_data_file        == DATA['panflu']['data']['population']
    assert ISP.contact_data_file           == DATA['panflu']['data']['contact']
    assert ISP.flow_data_file              == DATA['panflu']['data']['flow']
    assert ISP.vaccine_effectiveness_file  == DATA['panflu']['data']['vaccine_effectiveness']
    assert ISP.vaccine_adherence_file      == DATA['panflu']['data']['vaccine_adherence']
    assert ISP.high_risk_ratios_file       == DATA['panflu']['data']['high_risk_ratios']
    assert ISP.output_data_file            == DATA['panflu']['output']
    assert ISP.public_health_announcements == DATA['panflu']['public_health_announcements']
    assert ISP.vaccine_pro_rata            == DATA['panflu']['pro_rata']
    assert ISP.vaccine_universal           == DATA['panflu']['universal']
    assert ISP.initial                     == DATA['panflu']['initial']
    assert ISP.vaccines                    == DATA['panflu']['vaccines']

