import importlib.util
import sys
from pathlib import Path
from types import ModuleType

import pandas as pd
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
