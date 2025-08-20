import pytest

from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.baseclasses.Group import RiskGroup, VaccineGroup, Compartments, Group

@pytest.fixture
def pc_2_node():
    # Two age groups: 100 and 200 people
    # High-risk ratios: 0.0 (all low risk), 0.5 (half high risk)
    pc = PopulationCompartments(groups=[100, 200], high_risk_ratios=[0.0, 0.5])
    return pc

def test_by_group_only_unvaccinated_only_susceptible(pc_2_node):
    # Priority scheme: age0=0 (nobody), age1=0.5 (only HIGH risk in age1)
    pri = [0, 0.5]

    out = pc_2_node.vaccine_eligible_by_group(pri, only_unvaccinated=True, only_susceptible=True)
    # Expect exactly one tuple for age=1, risk=HIGH, value = susceptible high-risk in that cell
    assert len(out) == 1
    age, risk, val = out[0]
    assert age == 1
    assert risk == RiskGroup.H.value

    # Compute expected high-risk susceptibles in age group 1:
    expected = pc_2_node.compartment_data[1, RiskGroup.H.value, VaccineGroup.U.value, Compartments.S.value]
    assert val == float(expected)

def test_by_group_everyone_eligible_sum_matches(pc_2_node):
    pri = [1, 1]  # everyone in both ages
    # Count entire block for S only across both U and V if only_unvaccinated=False
    out = pc_2_node.vaccine_eligible_by_group(pri, only_unvaccinated=False, only_susceptible=True)

    # Should include (age0, low & high) and (age1, low & high) but only where counts > 0
    # In initialization, only U has people; V is zero, but we sum U and V together so result is same.
    # Age0: all 100 are low risk, high risk = 0
    # Age1: low=100, high=100 (because 0.5 high risk of 200)
    got = { (a, r): v for (a, r, v) in out }
    assert got[(0, RiskGroup.L.value)] == 100.0
    assert (0, RiskGroup.H.value) not in got or got[(0, RiskGroup.H.value)] == 0.0
    assert got[(1, RiskGroup.L.value)] == 100.0
    assert got[(1, RiskGroup.H.value)] == 100.0

def test_population_total_matches_sum_of_by_group(pc_2_node):
    pri = [1, 1]
    by_group_total = sum(v for _, _, v in pc_2_node.vaccine_eligible_by_group(age_risk_priority_groups = pri))
    pop_total = pc_2_node.vaccine_eligible_population(age_risk_priority_groups = pri)
    assert pop_total == by_group_total
    # Initialization places everyone in S, U:
    assert pop_total == float(sum(pc_2_node.groups))

def test_only_susceptible_false_counts_all_compartments(pc_2_node):
    # Move some people out of S to E and R to verify counting logic
    # Example: take 10 from age1, high-risk, unvaccinated => move 5 to E and 5 to R
    g = Group(age=1, risk_group=RiskGroup.H.value, vaccine_group=VaccineGroup.U.value)

    vec = list(pc_2_node.compartment_data[g.age, g.risk, g.vaccine, :])
    # vec[Compartments.S.value] currently 100
    vec[Compartments.S.value] -= 10
    vec[Compartments.E.value] += 5
    vec[Compartments.R.value] += 5
    pc_2_node.set_compartment_vector_for(g, vec)

    pri = [0, 1]  # only age1 eligible, both risks
    # Count everyone (S+E+A+T+I+R+D) among eligible groups
    pop_all = pc_2_node.vaccine_eligible_population(pri, only_unvaccinated=True, only_susceptible=False)

    # Expected: for age1 low-risk U: 100 people all in S
    #           for age1 high-risk U: 90 S + 5 E + 5 R = 100 people
    # Vaccinated (V) are zeros in init, and we're only_unvaccinated=True anyway.
    assert pop_all == 200.0

def test_len_mismatch_raises(pc_2_node):
    with pytest.raises(ValueError):
        pc_2_node.vaccine_eligible_by_group([1])  # wrong length

def test_invalid_priority_value_raises(pc_2_node):
    with pytest.raises(ValueError):
        pc_2_node.vaccine_eligible_by_group([0.25, 1.0])  # invalid value



