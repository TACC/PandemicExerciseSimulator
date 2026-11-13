"""Read age-specific risk fractions, matching county CSV rows by FIPS."""
import csv
from decimal import Decimal, InvalidOperation

import numpy as np


def canonical_fips(value):
    try:
        number = Decimal(str(value).strip())
        if not number.is_finite() or number < 0 or number != number.to_integral_value():
            raise ValueError
        return str(int(number)).zfill(5)
    except (InvalidOperation, ValueError):
        raise ValueError(f"Invalid county FIPS: {value!r}") from None


def parse_high_risk_ratios(lines, county_ids, age_groups):
    """Return county x age fractions in population-file order.

    Headerless state age vectors remain readable for legacy inputs. County CSVs
    require a FIPS column and the same age labels as the population file.
    """
    rows = [row for row in csv.reader(lines) if row and any(cell.strip() for cell in row)]
    if not rows:
        raise ValueError("High-risk ratio file is empty")
    if len(rows[0]) == 1:
        values = np.array([float(row[0]) for row in rows])
        if values.shape != (len(age_groups),):
            raise ValueError("State risk vector must contain one fraction per population age group")
        result = np.tile(values, (len(county_ids), 1))
    else:
        header = [cell.strip() for cell in rows[0]]
        if header[0].lower() != "fips" or len(set(header)) != len(header):
            raise ValueError("County risk CSV must have a unique fips/age header")
        if set(header[1:]) != set(map(str, age_groups)):
            raise ValueError("County risk age labels do not match the population file")
        indices = [header.index(str(age)) for age in age_groups]
        by_county = {}
        for row in rows[1:]:
            if len(row) != len(header):
                raise ValueError("County risk CSV has an inconsistent row length")
            fips = canonical_fips(row[0])
            if fips in by_county:
                raise ValueError(f"Duplicate county FIPS in risk CSV: {fips}")
            by_county[fips] = [float(row[index]) for index in indices]
        missing = [canonical_fips(fips) for fips in county_ids if canonical_fips(fips) not in by_county]
        if missing:
            raise ValueError(f"Missing county risk ratios for FIPS: {', '.join(missing)}")
        result = np.array([by_county[canonical_fips(fips)] for fips in county_ids])
    if not np.all(np.isfinite(result)) or np.any((result < 0) | (result > 1)):
        raise ValueError("High-risk ratios must be finite fractions between 0 and 1")
    return result
