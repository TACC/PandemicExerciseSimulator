#!/usr/bin/env python3
"""
Calibrate an age-stratified SEIHRD hospitalization curve with Epydemix ABC.

This script fits the repository's five-age-group SEIHRD parameterization to
Flu Scenario Modeling Hub age-stratified incident hospitalization time series.
It uses epydemix.calibration.ABCSampler for parameter sampling/selection and a
small deterministic SEIHRD simulator that mirrors the transition structure in
src/models/disease/StochasticSEIHRD.py.
"""

from __future__ import annotations

import argparse
import json
import math
import traceback
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
from scipy import stats

REPO_ROOT = Path(__file__).resolve().parents[1]

try:
    from epydemix.calibration import ABCSampler
except ImportError as exc:  # pragma: no cover - this is an environment guard.
    raise SystemExit(
        "epydemix is required for this calibration script. Install it with "
        "`pip install epydemix` or `pip install epydemix[numba]`."
    ) from exc


AGE_GROUPS = ["0-4", "5-17", "18-49", "50-64", "65+"]
FLU_HUB_AGE_RECODE = {"65-130": "65+"}
DEFAULT_INPUT_JSON = (
    REPO_ROOT
    / "STATE_INIT_TEST"
    / "SEED_INPUT_JSONS"
    / "INPUT_SEIHRD-STOCH_District-of-Columbia_SEED_NONE.json"
)
DEFAULT_HOSPITALIZATION_FILE = (
    REPO_ROOT / "data" / "FLU_HUB" / "time-series_2026-07-13.csv"
)


@dataclass(frozen=True)
class CalibrationData:
    dates: pd.DatetimeIndex
    simulation_start_date: pd.Timestamp
    observed: np.ndarray
    population: np.ndarray
    contact_matrix: np.ndarray
    high_risk_ratios: np.ndarray
    initial_exposed: np.ndarray


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fit age-stratified SEIHRD hospitalization parameters using Epydemix ABC."
    )
    parser.add_argument(
        "--input-json",
        type=Path,
        default=DEFAULT_INPUT_JSON,
        help="Simulator input JSON that supplies model parameters and state data files.",
    )
    parser.add_argument(
        "--all-states",
        action="store_true",
        help=(
            "Fit every no-intervention JSON in STATE_INIT_TEST/SEED_INPUT_JSONS. "
            "Per-state calibration outputs are written under --output-dir/<input-json-stem>/."
        ),
    )
    parser.add_argument(
        "--input-json-dir",
        type=Path,
        default=REPO_ROOT / "STATE_INIT_TEST" / "SEED_INPUT_JSONS",
        help="Directory searched when --all-states is set.",
    )
    parser.add_argument(
        "--input-json-glob",
        default="INPUT_SEIHRD-STOCH_*_SEED_NONE.json",
        help="Filename glob used with --all-states.",
    )
    parser.add_argument(
        "--hosp-file",
        type=Path,
        default=DEFAULT_HOSPITALIZATION_FILE,
        help="Flu Hub time-series CSV with age-stratified incident hospitalizations.",
    )
    parser.add_argument(
        "--location",
        default=None,
        help="Flu Hub location code. Defaults to the state FIPS inferred from the input population file.",
    )
    parser.add_argument(
        "--fit-start-date",
        default=None,
        help=(
            "First hospitalization week-ending date to fit, YYYY-MM-DD. Defaults to the first "
            "complete MMWR week ending on/after metadata_tags.sim_day_0."
        ),
    )
    parser.add_argument(
        "--fit-end-date",
        default=None,
        help="Last hospitalization week-ending date to fit, YYYY-MM-DD. Defaults to last available date.",
    )
    parser.add_argument(
        "--strategy",
        choices=["top_fraction", "rejection", "smc"],
        default="top_fraction",
        help="Epydemix ABC strategy.",
    )
    parser.add_argument("--nsim", type=int, default=300, help="Simulations for top_fraction.")
    parser.add_argument(
        "--top-fraction",
        type=float,
        default=0.05,
        help="Fraction of best simulations retained by top_fraction.",
    )
    parser.add_argument("--num-particles", type=int, default=200, help="Particles for rejection/SMC.")
    parser.add_argument("--num-generations", type=int, default=3, help="Generations for SMC.")
    parser.add_argument("--epsilon", type=float, default=0.35, help="Threshold for rejection ABC.")
    parser.add_argument("--seed", type=int, default=20260717, help="Random seed for reproducibility.")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=REPO_ROOT / "STATE_INIT_TEST" / "epydemix_fit",
        help="Directory for posterior, best-fit time series, and calibrated JSON output.",
    )
    parser.add_argument(
        "--write-calibrated-json",
        action="store_true",
        help="Write a copy of --input-json updated with calibrated R0.",
    )
    parser.add_argument(
        "--calibrated-json-estimator",
        choices=["best", "median"],
        default="best",
        help="Posterior estimate to write into the calibrated JSON. Defaults to best-distance particle.",
    )
    parser.add_argument(
        "--generated-metric",
        choices=["h_positive_increase", "admissions"],
        default="admissions",
        help=(
            "Model quantity compared with observed incident hospitalizations. "
            "admissions sums new IS-to-H flows over each observed MMWR week."
        ),
    )
    parser.add_argument(
        "--distance-objective",
        choices=["aggregate_peak", "pointwise_log"],
        default="aggregate_peak",
        help="Penalty used by ABC. aggregate_peak emphasizes all-age shape and peak timing.",
    )
    parser.add_argument(
        "--peak-week-weight",
        type=float,
        default=2.0,
        help="Weight for peak-week timing error when --distance-objective aggregate_peak.",
    )
    parser.add_argument(
        "--shape-weight",
        type=float,
        default=1.0,
        help="Weight for normalized all-age curve-shape error when --distance-objective aggregate_peak.",
    )
    parser.add_argument(
        "--peak-height-weight",
        type=float,
        default=0.15,
        help="Weight for peak-height log-ratio error when --distance-objective aggregate_peak.",
    )
    parser.add_argument(
        "--fit-initial-exposed-scale",
        action="store_true",
        help="Also fit a multiplier on the input JSON initial_exposed values. Off by default.",
    )
    parser.add_argument(
        "--initial-exposed-scale",
        type=float,
        default=1.0,
        help="Fixed initial_exposed multiplier used when --fit-initial-exposed-scale is not set.",
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help=(
            "Deprecated: --all-states now keeps fitting remaining states by default. "
            "Failures are reported in batch_manifest.json and cause a nonzero exit after the batch."
        ),
    )
    return parser.parse_args()


def resolve_repo_path(path: str | Path, base: Path) -> Path:
    candidate = Path(path)
    if candidate.is_absolute():
        return candidate
    from_json = (base / candidate).resolve()
    if from_json.exists():
        return from_json
    from_repo = (REPO_ROOT / candidate).resolve()
    if from_repo.exists():
        return from_repo
    parts = list(candidate.parts)
    while parts and parts[0] == "..":
        parts.pop(0)
    if parts:
        from_repo_stripped = (REPO_ROOT / Path(*parts)).resolve()
        if from_repo_stripped.exists():
            return from_repo_stripped
    return from_json


def numeric_vector(value: Any, label: str, expected: int = len(AGE_GROUPS)) -> np.ndarray:
    arr = np.asarray(value, dtype=float)
    if arr.size != expected or np.isnan(arr).any():
        raise ValueError(f"{label} must contain {expected} numeric values.")
    return arr.reshape(expected)


def numeric_scalar(value: Any, label: str) -> float:
    if isinstance(value, list):
        value = value[0]
    out = float(value)
    if math.isnan(out):
        raise ValueError(f"{label} must be numeric.")
    return out


def compute_w(
    prop_E_to_IA: np.ndarray,
    IP_to_IS_rate: float,
    IS_to_H_rate: float,
    IS_to_R_rate: float,
    IA_to_R_rate: float,
    rel_inf_IP: float = 1.0,
    rel_inf_IS: float = 1.0,
    rel_inf_IA: float = 1.0,
) -> np.ndarray:
    prop_E_to_IA = np.asarray(prop_E_to_IA, dtype=float)
    d_ip = 1.0 / IP_to_IS_rate
    d_is = 1.0 / (IS_to_H_rate + IS_to_R_rate)
    d_ia = 1.0 / IA_to_R_rate
    symptomatic_block = rel_inf_IP * d_ip + rel_inf_IS * d_is
    asymptomatic_block = rel_inf_IA * d_ia
    return (1.0 - prop_E_to_IA) * symptomatic_block + prop_E_to_IA * asymptomatic_block


def spectral_radius(matrix: np.ndarray) -> float:
    return float(np.max(np.linalg.eigvals(matrix).real))


def estimate_none_intervention_beta(
    contact_matrix: np.ndarray,
    R0: float,
    w: np.ndarray,
    susceptibility: np.ndarray,
) -> float:
    C = np.asarray(contact_matrix, dtype=float)
    M = np.diag(np.asarray(susceptibility, dtype=float)) @ C @ np.diag(np.asarray(w, dtype=float))
    rho = spectral_radius(M)
    if rho <= 0:
        raise ValueError("Spectral radius is non-positive; check contact matrix and rates.")
    return R0 / rho


def adjust_competing_clock_split_proportions(
    desired_realized_fractions: list[float],
    rates: list[float],
) -> list[float]:
    inverse_rate_weights = [
        desired_fraction / rate
        for desired_fraction, rate in zip(desired_realized_fractions, rates)
    ]
    denominator = sum(inverse_rate_weights)
    if denominator <= 0.0:
        raise ValueError("At least one desired realized fraction must be positive.")
    return [weight / denominator for weight in inverse_rate_weights]


def adjust_two_way_split_proportion(
    desired_realized_fraction: float,
    competing_rate: float,
    target_rate: float,
) -> float:
    if not (0.0 <= desired_realized_fraction <= 1.0):
        raise ValueError("desired_realized_fraction must be in [0, 1].")
    return adjust_competing_clock_split_proportions(
        desired_realized_fractions=[
            desired_realized_fraction,
            1.0 - desired_realized_fraction,
        ],
        rates=[target_rate, competing_rate],
    )[0]


def infer_location_from_population_file(population_file: Path) -> str:
    first_fips = pd.read_csv(population_file, dtype={"fips": str}, nrows=1)["fips"].iloc[0]
    return str(first_fips).zfill(5)[:2]


def first_complete_mmwr_week_end(start_date: pd.Timestamp) -> pd.Timestamp:
    """Return the first Saturday whose full Sun-Sat week starts on/after start_date."""
    start = pd.Timestamp(start_date).normalize()
    days_until_saturday = (5 - start.weekday()) % 7
    week_end = start + pd.Timedelta(days=days_until_saturday)
    week_start = week_end - pd.Timedelta(days=6)
    if week_start < start:
        week_end += pd.Timedelta(days=7)
    return week_end


def load_observed_hospitalizations(
    hospitalization_file: Path,
    location: str,
    fit_start_date: str | None,
    fit_end_date: str | None,
) -> tuple[pd.DatetimeIndex, np.ndarray]:
    flu = pd.read_csv(hospitalization_file, dtype={"location": str})
    flu["date"] = pd.to_datetime(flu["date"])
    flu["location"] = flu["location"].str.zfill(2)
    flu["age_group"] = flu["age_group"].replace(FLU_HUB_AGE_RECODE)

    filtered = flu[
        (flu["target"] == "inc hosp")
        & (flu["location"] == str(location).zfill(2))
        & (flu["age_group"].isin(AGE_GROUPS))
    ].copy()

    non_saturday_dates = filtered.loc[filtered["date"].dt.weekday != 5, "date"].drop_duplicates()
    if not non_saturday_dates.empty:
        examples = ", ".join(non_saturday_dates.dt.date.astype(str).head(3))
        raise ValueError(
            "Expected Flu Hub inc hosp records to be MMWR week-ending Saturdays; "
            f"found non-Saturday date(s): {examples}."
        )

    if fit_start_date:
        filtered = filtered[filtered["date"] >= pd.Timestamp(fit_start_date)]
    if fit_end_date:
        filtered = filtered[filtered["date"] <= pd.Timestamp(fit_end_date)]
    if filtered.empty:
        raise ValueError(
            f"No age-stratified inc hosp records found for location {location} in {hospitalization_file}."
        )

    wide = (
        filtered.pivot_table(
            index="date",
            columns="age_group",
            values="observation",
            aggfunc="sum",
            fill_value=0.0,
        )
        .reindex(columns=AGE_GROUPS, fill_value=0.0)
        .sort_index()
    )
    return pd.DatetimeIndex(wide.index), wide.to_numpy(dtype=float)


def load_config_and_data(args: argparse.Namespace) -> tuple[dict[str, Any], CalibrationData]:
    input_json = args.input_json.resolve()
    with open(input_json) as fp:
        config = json.load(fp)

    data_base = input_json.parent
    population_file = resolve_repo_path(config["data"]["population"], data_base)
    contact_file = resolve_repo_path(config["data"]["contact"], data_base)
    high_risk_file = resolve_repo_path(config["data"]["high_risk_ratios"], data_base)
    location = args.location or infer_location_from_population_file(population_file)

    population_df = pd.read_csv(population_file, dtype={"fips": str})
    population = population_df[AGE_GROUPS].sum(axis=0).to_numpy(dtype=float)
    contact_matrix = np.genfromtxt(contact_file, delimiter=",")
    high_risk_ratios = np.genfromtxt(high_risk_file, delimiter=",")

    initial_exposed = np.zeros(len(AGE_GROUPS), dtype=float)
    for row in config.get("initial_exposed", []):
        age = int(row["age_group"])
        initial_exposed[age] += float(row["infected"])

    simulation_start_date = pd.Timestamp(
        config.get("metadata_tags", {}).get("sim_day_0")
        or args.fit_start_date
        or "2025-10-01"
    )
    first_full_week_end = first_complete_mmwr_week_end(simulation_start_date)
    requested_fit_start = (
        pd.Timestamp(args.fit_start_date)
        if args.fit_start_date
        else first_full_week_end
    )
    fit_start_date = max(requested_fit_start, first_full_week_end).date().isoformat()
    dates, observed = load_observed_hospitalizations(
        args.hosp_file.resolve(),
        location=location,
        fit_start_date=fit_start_date,
        fit_end_date=args.fit_end_date,
    )

    return config, CalibrationData(
        dates=dates,
        simulation_start_date=simulation_start_date,
        observed=observed,
        population=population,
        contact_matrix=contact_matrix,
        high_risk_ratios=np.asarray(high_risk_ratios, dtype=float),
        initial_exposed=initial_exposed,
    )


def build_base_parameters(config: dict[str, Any], data: CalibrationData) -> dict[str, Any]:
    disease = config["disease_model"]["parameters"]
    prop_e_to_ia = numeric_vector(disease["prop_E_to_IA"], "prop_E_to_IA")
    prop_is_to_h_lowrisk = numeric_vector(
        disease["prop_IS_to_H_lowrisk"], "prop_IS_to_H_lowrisk"
    )
    highrisk_hosp_multiplier = numeric_scalar(
        disease["highrisk_hosp_multiplier"], "highrisk_hosp_multiplier"
    )
    highrisk = np.clip(highrisk_hosp_multiplier * prop_is_to_h_lowrisk, 0.0, 0.95)
    hosp_prob = (
        (1.0 - data.high_risk_ratios) * prop_is_to_h_lowrisk
        + data.high_risk_ratios * highrisk
    )

    return {
        "population": data.population,
        "contact_matrix": data.contact_matrix,
        "initial_exposed_base": data.initial_exposed,
        "relative_susceptibility": numeric_vector(
            disease.get("relative_susceptibility", [1.0] * len(AGE_GROUPS)),
            "relative_susceptibility",
        ),
        "prop_E_to_IA": prop_e_to_ia,
        "hosp_prob": hosp_prob,
        "prop_H_to_D": numeric_vector(disease["prop_H_to_D"], "prop_H_to_D"),
        "E_out_rate": 1.0 / numeric_scalar(disease["E_to_IPandIA_days"], "E_to_IPandIA_days"),
        "IP_to_IS_rate": 1.0 / numeric_scalar(disease["IP_to_IS_days"], "IP_to_IS_days"),
        "IS_to_H_rate": 1.0 / numeric_scalar(disease["IS_to_H_days"], "IS_to_H_days"),
        "IS_to_R_rate": 1.0 / numeric_scalar(disease["IS_to_R_days"], "IS_to_R_days"),
        "H_to_D_rate": 1.0 / numeric_scalar(disease["H_to_D_days"], "H_to_D_days"),
        "H_to_R_rates": 1.0 / numeric_vector(disease["H_to_R_days"], "H_to_R_days"),
        "IA_to_R_rate": 1.0 / numeric_scalar(disease["IA_to_R_days"], "IA_to_R_days"),
        "rel_inf_IP_to_IS": numeric_scalar(disease["rel_inf_IP_to_IS"], "rel_inf_IP_to_IS"),
        "rel_inf_IA_to_IS": numeric_scalar(disease["rel_inf_IA_to_IS"], "rel_inf_IA_to_IS"),
        "dates": data.dates,
        "simulation_start_date": data.simulation_start_date,
        "generated_metric": None,
        "initial_exposed_scale": None,
    }


def corrected_split_rates(params: dict[str, Any]) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    prop_is_to_h = np.array(
        [
            adjust_two_way_split_proportion(
                desired_realized_fraction=p,
                competing_rate=params["IS_to_R_rate"],
                target_rate=params["IS_to_H_rate"],
            )
            for p in params["hosp_prob"]
        ]
    )
    prop_h_to_d = np.array(
        [
            adjust_two_way_split_proportion(
                desired_realized_fraction=p,
                competing_rate=r_rate,
                target_rate=params["H_to_D_rate"],
            )
            for p, r_rate in zip(params["prop_H_to_D"], params["H_to_R_rates"])
        ]
    )
    is_to_h = prop_is_to_h * params["IS_to_H_rate"]
    is_to_r = (1.0 - prop_is_to_h) * params["IS_to_R_rate"]
    h_to_d = prop_h_to_d * params["H_to_D_rate"]
    h_to_r = (1.0 - prop_h_to_d) * params["H_to_R_rates"]
    return is_to_h, is_to_r, h_to_d, h_to_r


def none_intervention_beta(params: dict[str, Any]) -> float:
    w = compute_w(
        params["prop_E_to_IA"],
        params["IP_to_IS_rate"],
        params["IS_to_H_rate"],
        params["IS_to_R_rate"],
        params["IA_to_R_rate"],
        rel_inf_IP=params["rel_inf_IP_to_IS"],
        rel_inf_IA=params["rel_inf_IA_to_IS"],
    )
    return estimate_none_intervention_beta(
        params["contact_matrix"],
        float(params["R0"]),
        w,
        params["relative_susceptibility"],
    )


def simulate_seihrd(params: dict[str, Any]) -> dict[str, Any]:
    dates = params["dates"]
    simulation_start_date = pd.Timestamp(params["simulation_start_date"])
    n_days = int((dates[-1] - simulation_start_date).days) + 1
    if n_days < 1:
        raise ValueError("Observed dates must end after the simulation start date.")
    n_age = len(AGE_GROUPS)
    pop = np.asarray(params["population"], dtype=float)
    initial_e = np.maximum(
        1.0,
        np.asarray(params["initial_exposed_base"], dtype=float)
        * float(params["initial_exposed_scale"]),
    )

    S = np.maximum(pop - initial_e, 0.0)
    E = initial_e.copy()
    IA = np.zeros(n_age)
    IP = np.zeros(n_age)
    IS = np.zeros(n_age)
    H = np.zeros(n_age)
    R = np.zeros(n_age)
    D = np.zeros(n_age)

    beta = none_intervention_beta(params)
    is_to_h_rate, is_to_r_rate, h_to_d_rate, h_to_r_rate = corrected_split_rates(params)
    weekly_metric = []

    date_to_day = {int((date - simulation_start_date).days): idx for idx, date in enumerate(dates)}
    daily_hosp_buffer = []

    for day in range(n_days + 1):
        h_before = H.copy()
        infectious = (
            params["rel_inf_IA_to_IS"] * IA
            + params["rel_inf_IP_to_IS"] * IP
            + IS
        )
        force = (
            beta
            * params["relative_susceptibility"]
            * (params["contact_matrix"] @ (infectious / pop.sum()))
        )

        new_exposed = np.minimum(S, force * S)
        e_out = np.minimum(E, params["E_out_rate"] * E)
        e_to_ia = params["prop_E_to_IA"] * e_out
        e_to_ip = e_out - e_to_ia
        ip_to_is = np.minimum(IP, params["IP_to_IS_rate"] * IP)
        ia_to_r = np.minimum(IA, params["IA_to_R_rate"] * IA)
        is_to_h = np.minimum(IS, is_to_h_rate * IS)
        is_remaining = np.maximum(IS - is_to_h, 0.0)
        is_to_r = np.minimum(is_remaining, is_to_r_rate * is_remaining)
        h_to_d = np.minimum(H, h_to_d_rate * H)
        h_remaining = np.maximum(H - h_to_d, 0.0)
        h_to_r = np.minimum(h_remaining, h_to_r_rate * h_remaining)

        S -= new_exposed
        E += new_exposed - e_out
        IA += e_to_ia - ia_to_r
        IP += e_to_ip - ip_to_is
        IS += ip_to_is - is_to_h - is_to_r
        H += is_to_h - h_to_d - h_to_r
        R += ia_to_r + is_to_r + h_to_r
        D += h_to_d

        if params.get("generated_metric") == "admissions":
            daily_metric = is_to_h.copy()
        else:
            daily_metric = np.maximum(H - h_before, 0.0)

        daily_hosp_buffer.append(daily_metric)
        if day in date_to_day:
            window = daily_hosp_buffer[-7:]
            weekly_metric.append(np.sum(window, axis=0) if window else np.zeros(n_age))

    return {
        "data": np.asarray(weekly_metric, dtype=float),
        "initial_exposed": initial_e,
    }


def log_weighted_rmse(data: dict[str, Any], simulation: dict[str, Any]) -> float:
    observed = np.asarray(data["data"], dtype=float)
    simulated = np.asarray(simulation["data"], dtype=float)
    if observed.shape != simulated.shape:
        raise ValueError(f"Observed shape {observed.shape} != simulated shape {simulated.shape}")
    weights = 1.0 / np.sqrt(np.maximum(observed, 1.0))
    error = (np.log1p(simulated) - np.log1p(observed)) * weights
    return float(np.sqrt(np.mean(error * error)))


def aggregate_peak_distance(
    data: dict[str, Any],
    simulation: dict[str, Any],
    *,
    peak_week_weight: float,
    shape_weight: float,
    peak_height_weight: float,
) -> float:
    observed = np.asarray(data["data"], dtype=float).sum(axis=1)
    simulated = np.asarray(simulation["data"], dtype=float).sum(axis=1)
    if observed.shape != simulated.shape:
        raise ValueError(f"Observed shape {observed.shape} != simulated shape {simulated.shape}")

    eps = 1e-9
    observed_shape = observed / max(observed.sum(), eps)
    simulated_shape = simulated / max(simulated.sum(), eps)
    shape_error = float(np.sqrt(np.mean((simulated_shape - observed_shape) ** 2)))

    observed_peak_week = int(np.argmax(observed))
    simulated_peak_week = int(np.argmax(simulated))
    peak_week_error = abs(simulated_peak_week - observed_peak_week) / max(len(observed) - 1, 1)

    peak_height_error = abs(
        math.log((simulated.max() + 1.0) / (observed.max() + 1.0))
    )

    return (
        shape_weight * shape_error
        + peak_week_weight * peak_week_error
        + peak_height_weight * peak_height_error
    )


def make_distance_function(args: argparse.Namespace):
    if args.distance_objective == "pointwise_log":
        return log_weighted_rmse

    def distance(data: dict[str, Any], simulation: dict[str, Any]) -> float:
        return aggregate_peak_distance(
            data,
            simulation,
            peak_week_weight=args.peak_week_weight,
            shape_weight=args.shape_weight,
            peak_height_weight=args.peak_height_weight,
        )

    return distance


def build_priors(args: argparse.Namespace) -> dict[str, Any]:
    priors = {
        "R0": stats.uniform(1.01, 2.49),  # 1.01 to 3.5
    }
    if args.fit_initial_exposed_scale:
        priors["initial_exposed_scale"] = stats.loguniform(0.25, 4.0)
    return priors


def run_calibration(
    base_params: dict[str, Any],
    observed: np.ndarray,
    args: argparse.Namespace,
):
    np.random.seed(args.seed)
    params = {
        **base_params,
        "generated_metric": args.generated_metric,
        "initial_exposed_scale": args.initial_exposed_scale,
    }
    sampler = ABCSampler(
        simulation_function=simulate_seihrd,
        priors=build_priors(args),
        parameters=params,
        observed_data=observed,
        distance_function=make_distance_function(args),
    )
    if args.strategy == "top_fraction":
        return sampler.calibrate(
            strategy="top_fraction",
            top_fraction=args.top_fraction,
            Nsim=args.nsim,
            verbose=True,
        )
    if args.strategy == "rejection":
        return sampler.calibrate(
            strategy="rejection",
            epsilon=args.epsilon,
            num_particles=args.num_particles,
            verbose=True,
        )
    return sampler.calibrate(
        strategy="smc",
        num_particles=args.num_particles,
        num_generations=args.num_generations,
        verbose=True,
    )


def posterior_with_distances(results: Any) -> pd.DataFrame:
    generation = max(results.posterior_distributions)
    posterior = results.posterior_distributions[generation].reset_index(drop=True).copy()
    posterior["distance"] = np.asarray(results.distances[generation], dtype=float)
    posterior["weight"] = np.asarray(results.weights[generation], dtype=float)
    return posterior.sort_values("distance").reset_index(drop=True)


def write_best_fit_timeseries(
    output_file: Path,
    dates: pd.DatetimeIndex,
    observed: np.ndarray,
    simulated: np.ndarray,
) -> None:
    rows = []
    for t, date in enumerate(dates):
        for a, age_group in enumerate(AGE_GROUPS):
            rows.append(
                {
                    "date": date.date().isoformat(),
                    "age_group": age_group,
                    "observed_incident_hospitalizations": observed[t, a],
                    "fitted_incident_hospitalizations": simulated[t, a],
                }
            )
    pd.DataFrame(rows).to_csv(output_file, index=False)


def summarize_aggregate_fit(
    dates: pd.DatetimeIndex,
    observed: np.ndarray,
    simulated: np.ndarray,
) -> dict[str, Any]:
    observed_total = np.asarray(observed, dtype=float).sum(axis=1)
    simulated_total = np.asarray(simulated, dtype=float).sum(axis=1)
    observed_peak_index = int(np.argmax(observed_total))
    simulated_peak_index = int(np.argmax(simulated_total))
    return {
        "observed_peak_date": dates[observed_peak_index].date().isoformat(),
        "fitted_peak_date": dates[simulated_peak_index].date().isoformat(),
        "peak_lag_weeks": simulated_peak_index - observed_peak_index,
        "observed_peak_height": float(observed_total[observed_peak_index]),
        "fitted_peak_height": float(simulated_total[simulated_peak_index]),
        "observed_total": float(observed_total.sum()),
        "fitted_total": float(simulated_total.sum()),
    }


def update_calibrated_json(
    config: dict[str, Any],
    base_params: dict[str, Any],
    calibrated_params: dict[str, float],
    output_file: Path,
    estimator: str,
    rewrite_initial_exposed: bool,
) -> None:
    calibrated = json.loads(json.dumps(config))
    posterior_params = {**base_params, **calibrated_params}
    fitted_initial = None
    if rewrite_initial_exposed:
        fitted_initial = simulate_seihrd(posterior_params).get("initial_exposed")
        fitted_initial = np.maximum(0, np.rint(fitted_initial).astype(int))

    calibrated["disease_model"]["parameters"]["R0"] = f"{calibrated_params['R0']:.6g}"
    calibrated.setdefault("metadata_tags", {})
    calibrated["metadata_tags"].setdefault("notes", [])
    calibrated["metadata_tags"]["notes"].append(
        "R0 calibrated with scripts/5b_epydemix_fit_seihrd_hospitalizations.py."
    )
    calibrated["metadata_tags"]["epydemix_fit"] = {
        "fit_created_at": datetime.now().isoformat(timespec="seconds"),
        "estimator": estimator,
        "R0": calibrated_params["R0"],
        "initial_exposed_scale": posterior_params["initial_exposed_scale"],
        "initial_exposed_preserved": not rewrite_initial_exposed,
        "fitted_parameters": list(calibrated_params.keys()),
        "fit_start_date": str(pd.Timestamp(base_params["dates"][0]).date()),
        "fit_end_date": str(pd.Timestamp(base_params["dates"][-1]).date()),
        "simulation_start_date": str(pd.Timestamp(base_params["simulation_start_date"]).date()),
        "mmwr_week_alignment": "Sun-Sat weeks dated by Saturday; partial first week skipped",
        "generated_metric": base_params.get("generated_metric"),
    }
    if not rewrite_initial_exposed:
        with open(output_file, "w") as fp:
            json.dump(calibrated, fp, indent=2)
            fp.write("\n")
        return

    rows = []
    original_rows = calibrated.get("initial_exposed", [])
    for age, value in enumerate(fitted_initial):
        if value <= 0:
            continue
        age_rows = [row for row in original_rows if int(row["age_group"]) == age]
        if not age_rows:
            rows.append({"county": "UNKNOWN", "infected": str(int(value)), "age_group": str(age)})
            continue
        original_total = sum(float(row["infected"]) for row in age_rows)
        weights = (
            np.array([float(row["infected"]) for row in age_rows]) / original_total
            if original_total > 0
            else np.ones(len(age_rows)) / len(age_rows)
        )
        raw = weights * value
        floored = np.floor(raw).astype(int)
        remainder = int(value) - int(floored.sum())
        if remainder > 0:
            order = np.argsort(raw - floored)[::-1]
            floored[order[:remainder]] += 1
        for row, infected in zip(age_rows, floored):
            if infected > 0:
                rows.append(
                    {
                        "county": str(row["county"]),
                        "infected": str(int(infected)),
                        "age_group": str(age),
                    }
                )
    calibrated["initial_exposed"] = rows
    with open(output_file, "w") as fp:
        json.dump(calibrated, fp, indent=2)
        fp.write("\n")


def discover_input_jsons(args: argparse.Namespace) -> list[Path]:
    input_json_dir = args.input_json_dir.resolve()
    input_jsons = sorted(input_json_dir.glob(args.input_json_glob))
    if not input_jsons:
        raise FileNotFoundError(
            f"No input JSONs matched {args.input_json_glob!r} in {input_json_dir}."
        )
    return input_jsons


def state_label_from_input_json(input_json: Path) -> str:
    state = input_json.stem
    state = state.removeprefix("INPUT_SEIHRD-STOCH_")
    state = state.removesuffix("_SEED_NONE")
    return state.replace("-", " ")


def run_one(args: argparse.Namespace) -> dict[str, Any]:
    if args.initial_exposed_scale <= 0:
        raise ValueError("--initial-exposed-scale must be positive.")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    config, data = load_config_and_data(args)
    base_params = build_base_parameters(config, data)
    base_params["generated_metric"] = args.generated_metric
    base_params["initial_exposed_scale"] = args.initial_exposed_scale
    results = run_calibration(base_params, data.observed, args)
    posterior = posterior_with_distances(results)

    posterior_file = args.output_dir / "posterior_samples.csv"
    posterior.to_csv(posterior_file, index=False)

    best_params = posterior.iloc[0].drop(labels=["distance", "weight"]).to_dict()
    best_sim = simulate_seihrd({**base_params, **best_params})
    median_params = posterior.drop(columns=["distance", "weight"]).median().to_dict()

    best_params_file = args.output_dir / "best_parameters.json"
    with open(best_params_file, "w") as fp:
        json.dump(
            {
                "distance": float(posterior.iloc[0]["distance"]),
                "parameters": best_params,
                "posterior_median": median_params,
                "generated_metric": args.generated_metric,
                "distance_objective": args.distance_objective,
                "aggregate_fit_summary": summarize_aggregate_fit(
                    data.dates,
                    data.observed,
                    best_sim["data"],
                ),
            },
            fp,
            indent=2,
        )
        fp.write("\n")

    fit_file = args.output_dir / "best_fit_timeseries.csv"
    write_best_fit_timeseries(fit_file, data.dates, data.observed, best_sim["data"])

    calibrated_json_file = None
    if args.write_calibrated_json:
        mode_label = "R0_ONLY" if not args.fit_initial_exposed_scale else "R0_INIT_SCALE"
        calibrated_json_file = args.output_dir / f"{args.input_json.stem}_EPYDEMIX_{mode_label}.json"
        calibrated_params = best_params if args.calibrated_json_estimator == "best" else median_params
        update_calibrated_json(
            config,
            base_params,
            calibrated_params,
            calibrated_json_file,
            estimator=args.calibrated_json_estimator,
            rewrite_initial_exposed=args.fit_initial_exposed_scale or args.initial_exposed_scale != 1.0,
        )

    print(f"Wrote posterior samples: {posterior_file}")
    print(f"Wrote best parameters: {best_params_file}")
    print(f"Wrote best-fit time series: {fit_file}")
    if calibrated_json_file:
        print(
            f"Wrote calibrated simulator JSON ({args.calibrated_json_estimator}): "
            f"{calibrated_json_file}"
        )
        print("Calibrated JSON parameters:", json.dumps(calibrated_params, indent=2))
    print("Best distance:", float(posterior.iloc[0]["distance"]))
    print("Best parameters:", json.dumps(best_params, indent=2))
    print(
        "Aggregate fit summary:",
        json.dumps(summarize_aggregate_fit(data.dates, data.observed, best_sim["data"]), indent=2),
    )
    return {
        "input_json": str(args.input_json),
        "output_dir": str(args.output_dir),
        "posterior_file": str(posterior_file),
        "best_params_file": str(best_params_file),
        "fit_file": str(fit_file),
        "calibrated_json_file": str(calibrated_json_file) if calibrated_json_file else None,
        "best_distance": float(posterior.iloc[0]["distance"]),
        "best_params": best_params,
    }


def main() -> None:
    args = parse_args()
    if not args.all_states:
        run_one(args)
        return

    input_jsons = discover_input_jsons(args)
    base_output_dir = args.output_dir.resolve()
    base_output_dir.mkdir(parents=True, exist_ok=True)
    print(f"Discovered {len(input_jsons)} input JSONs in {args.input_json_dir.resolve()}")

    results = []
    failures = []
    for index, input_json in enumerate(input_jsons, start=1):
        state_args = argparse.Namespace(**vars(args))
        state_args.input_json = input_json
        state_args.output_dir = base_output_dir / input_json.stem
        state_label = state_label_from_input_json(input_json)
        started_at = datetime.now()
        print(
            f"[{index}/{len(input_jsons)}] START {state_label}: {input_json.name}",
            flush=True,
        )
        try:
            result = run_one(state_args)
            results.append(result)
            elapsed = datetime.now() - started_at
            print(
                f"[{index}/{len(input_jsons)}] OK {state_label}: "
                f"best_distance={result['best_distance']:.6g}; elapsed={elapsed}",
                flush=True,
            )
        except Exception as exc:
            elapsed = datetime.now() - started_at
            failures.append(
                {
                    "input_json": str(input_json),
                    "state": state_label,
                    "error": str(exc),
                    "traceback": traceback.format_exc(),
                }
            )
            print(
                f"[{index}/{len(input_jsons)}] FAIL {state_label}: {exc}; "
                f"elapsed={elapsed}",
                flush=True,
            )
            print("Continuing to next state.", flush=True)

    manifest = {
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "input_json_dir": str(args.input_json_dir.resolve()),
        "input_json_glob": args.input_json_glob,
        "result_count": len(results),
        "failure_count": len(failures),
        "results": results,
        "failures": failures,
    }
    manifest_file = base_output_dir / "batch_manifest.json"
    with open(manifest_file, "w") as fp:
        json.dump(manifest, fp, indent=2)
        fp.write("\n")
    print(f"Wrote batch manifest: {manifest_file}")
    if failures:
        print("Failed state fits:", flush=True)
        for failure in failures:
            print(f"  - {failure['state']}: {failure['error']}", flush=True)
        raise SystemExit(f"{len(failures)} state fits failed; see {manifest_file}")


if __name__ == "__main__":
    main()
