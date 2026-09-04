from hypothesis import example, given
from hypothesis import strategies as st

from lib.package_a import module_x


@given(s=st.text())
@example(s="abc")
def test_f1_property(s):
    """Property-based test: f1 should return valid SHA-256 hash for any input"""

    res = module_x.f1({"event_data": s})

    # Check it returns a 64-character hex string (SHA-256 property)
    assert isinstance(res, str)
    assert len(res) == 64
    assert all(c in "0123456789abcdef" for c in res)

    # Verify specific example
    if s == "abc":
        assert res == "de5ea8bb1eddc53f5a1e8ee2f855e393b31d6af626bf23515df661988641fbe8"
