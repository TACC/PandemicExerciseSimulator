import pytest
import importlib
from src.baseclasses import Group
from src.baseclasses.Group import Compartments

# Reset the dynamic enum before each test
@pytest.fixture(autouse=True)
def reset_compartments():
    importlib.reload(Group)  # puts _active_compartments back to None
    yield
    importlib.reload(Group)


def test_access_before_set_raises():
    with pytest.raises(RuntimeError):
        _ = Compartments.S  # proxy should complain when not set


@pytest.mark.parametrize(
    "labels, expect_members",
    [
        (["S", "E", "I", "R"], {"S", "E", "I", "R"}),
        (["S", "E", "A", "T", "I", "R", "D"], {"S", "E", "A", "T", "I", "R", "D"}),
        ([" s ", "e", "i", "r "], {"S", "E", "I", "R"}),  # trims/uppercases
    ],
)
def test_set_compartments_exposes_members(labels, expect_members):
    Group.set_compartments(labels)
    # Names present and length matches
    names = {m.name for m in Compartments}
    assert names == expect_members
    # S exists and is index of its position
    assert hasattr(Compartments, "S")
    # Verify values are consistent with order provided (after clean-up)
    cleaned = [str(x).strip().upper() for x in labels]
    # remove duplicates if user passed weird input (set_compartments should already have rejected)
    assert [m.name for m in Compartments] == cleaned
    # direct access works
    _ = Compartments.S.value
    _ = Compartments.E.value


def test_missing_S_raises():
    with pytest.raises(ValueError):
        Group.set_compartments(["E", "I", "R"])  # must include S


def test_missing_E_raises():
    with pytest.raises(ValueError):
        Group.set_compartments(["S", "I", "R"])  # must include E


def test_duplicate_labels_raises():
    with pytest.raises(ValueError):
        Group.set_compartments(["S", "E", "E", "R"])


@pytest.mark.parametrize("bad", [["S", "E", "I-", "R"], ["S", "E", "I R"], ["S", "E", "I*", "R"]])
def test_invalid_identifier_labels_raise(bad):
    with pytest.raises(ValueError):
        Group.set_compartments(bad)


def test_reconfigure_updates_proxy():
    # First configuration
    Group.set_compartments(["S", "E", "I", "R"])
    assert hasattr(Compartments, "I")
    with pytest.raises(AttributeError):
        _ = Compartments.A  # not present yet

    # Reconfigure to longer list (A,T,D present)
    Group.set_compartments(["S", "E", "A", "T", "I", "R", "D"])
    assert hasattr(Compartments, "A")
    assert hasattr(Compartments, "T")
    assert hasattr(Compartments, "D")
    # Order respected
    assert [m.name for m in Compartments] == ["S", "E", "A", "T", "I", "R", "D"]


def test_len_iter_repr_basic():
    Group.set_compartments(["S", "E", "I", "R"])
    # len / iter work
    assert len(Compartments) == 4
    names = [m.name for m in Compartments]
    assert names == ["S", "E", "I", "R"]
    # repr doesn’t raise and mentions 'Compartments'
    r = repr(Compartments)
    assert "Compartments" in r
