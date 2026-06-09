import numpy as np

from src.models.disease.StochasticSEIRS import SEITRS_model


class FloorPoissonRng:
    def poisson(self, lam):
        return int(lam)


def test_seitrs_model_does_not_create_treated_without_antivirals():
    y = np.array([100.0, 10.0, 8.0, 5.0, 20.0])

    daily_change = SEITRS_model(
        y,
        0.0,   # S => E
        0.2,   # E => I
        0.5,   # I => R
        0.2,   # T => R
        0.1,   # R => S
        rng=FloorPoissonRng(),
    )

    np.testing.assert_allclose(
        daily_change,
        np.array([2.0, -2.0, -2.0, -1.0, 3.0]),
    )
    assert np.isclose(daily_change.sum(), 0.0)
