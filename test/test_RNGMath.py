from src.utils.RNGMath import rand_binomial, rand_mt, rand_exp, rand_int

class TestRNGMath:
    def test_rand_mt_range(self):
        for _ in range(100):
            val = rand_mt()
            assert 0 <= val < 1

    def test_rand_exp_range(self):
        for _ in range(100):
            val = rand_exp(1.0)
            assert val >= 0

    def test_rand_int_range(self):
        for _ in range(100):
            val = rand_int(0, 10)
            assert 0 <= val <= 10

    def test_rand_int_edge_cases(self):
        assert rand_int(0, 0) == 0
        assert rand_int(10, 10) == 10

    def test_rand_binomial_range(self):
        for _ in range(100):
            val = rand_binomial(10, 0.5)
            assert 0 <= val <= 10

    def test_rand_binomial_edge_cases(self):
        assert rand_binomial(0, 0.5) == 0
        assert rand_binomial(10, 0.0) == 0
        assert rand_binomial(10, 1.0) == 10
