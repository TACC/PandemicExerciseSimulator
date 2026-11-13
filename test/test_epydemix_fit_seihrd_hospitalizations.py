import importlib.util
import sys
from pathlib import Path
from types import ModuleType

import pandas as pd
import numpy as np
import pytest


def load_fit_script():
    epydemix = ModuleType("epydemix")
    calibration = ModuleType("epydemix.calibration")
    calibration.ABCSampler = object
    sys.modules.setdefault("epydemix", epydemix)
    sys.modules.setdefault("epydemix.calibration", calibration)

    script_path = (
        Path(__file__).resolve().parents[1]
        / "scripts"
        / "5b_epydemix_fit_seihrd_hospitalizations.py"
    )
    spec = importlib.util.spec_from_file_location("epydemix_fit_seihrd_hospitalizations", script_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_first_complete_mmwr_week_end_skips_partial_start_week():
    fit = load_fit_script()

    assert fit.first_complete_mmwr_week_end(pd.Timestamp("2025-10-01")) == pd.Timestamp("2025-10-11")
    assert fit.first_complete_mmwr_week_end(pd.Timestamp("2025-10-05")) == pd.Timestamp("2025-10-11")


def test_observed_hospitalizations_are_weekly_saturday_records(tmp_path):
    fit = load_fit_script()
    hosp_file = tmp_path / "hosp.csv"
    hosp_file.write_text(
        "date,location,age_group,target,observation\n"
        "2025-10-04,01,0-4,inc hosp,2\n"
        "2025-10-11,01,0-4,inc hosp,3\n"
        "2025-10-11,01,5-17,inc hosp,4\n"
    )

    dates, observed = fit.load_observed_hospitalizations(
        hosp_file,
        location="01",
        fit_start_date="2025-10-11",
        fit_end_date=None,
    )

    assert dates.tolist() == [pd.Timestamp("2025-10-11")]
    assert observed.tolist() == [[3.0, 4.0, 0.0, 0.0, 0.0]]


def test_observed_hospitalizations_reject_non_saturday_dates(tmp_path):
    fit = load_fit_script()
    hosp_file = tmp_path / "hosp.csv"
    hosp_file.write_text(
        "date,location,age_group,target,observation\n"
        "2025-10-10,01,0-4,inc hosp,2\n"
    )

    with pytest.raises(ValueError, match="week-ending Saturdays"):
        fit.load_observed_hospitalizations(
            hosp_file,
            location="01",
            fit_start_date=None,
            fit_end_date=None,
        )


def test_parse_args_defaults_to_incident_hospitalization_target(monkeypatch):
    fit = load_fit_script()
    monkeypatch.setattr(sys, "argv", ["fit.py"])

    args = fit.parse_args()

    assert args.fit_target == "hosp_incident"
    assert args.generated_metric == "admissions"


def test_calibration_aggregates_county_risk_by_age_population(tmp_path):
    fit = load_fit_script()
    population = pd.DataFrame({"fips": ["01001", "01003"], **{
        age: values for age, values in zip(fit.AGE_GROUPS, [[100,300],[200,100],[100,300],[200,100],[100,300]])
    }})
    path = tmp_path / "risk.csv"
    path.write_text("fips,0-4,5-17,18-49,50-64,65+\n01003,.5,.6,.7,.8,.9\n01001,.1,.2,.3,.4,.5\n")
    np.testing.assert_allclose(fit.population_weighted_risk(path, population), [.4, 1/3, .6, 8/15, .8])


def test_parse_args_accepts_deprecated_generated_metric_alias(monkeypatch):
    fit = load_fit_script()
    monkeypatch.setattr(sys, "argv", ["fit.py", "--generated-metric", "h_positive_increase"])

    args = fit.parse_args()

    assert args.fit_target == "hosp_increase"
    assert args.generated_metric == "h_positive_increase"


def test_parse_args_rejects_conflicting_fit_target_and_generated_metric(monkeypatch):
    fit = load_fit_script()
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "fit.py",
            "--fit-target",
            "hosp_increase",
            "--generated-metric",
            "admissions",
        ],
    )

    with pytest.raises(SystemExit):
        fit.parse_args()
