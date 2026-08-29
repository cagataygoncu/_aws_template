from collections import defaultdict

from hypothesis import example, given, strategies as st

from lib.package_a import module_x


@given(s=st.text())
@example(s="abc")
def test_f1_property(s):
    """Property-based test: f1 should return valid SHA-256 hash for any input"""

    res = module_x.f1(defaultdict(dict), {"event_data": s})

    # Check it returns a 64-character hex string (SHA-256 property)
    assert isinstance(res, str)
    assert len(res) == 64
    assert all(c in "0123456789abcdef" for c in res)

    # Verify specific example
    if s == "abc":
        assert res == "8e11d5f3aabb95357d7082d9f7cda405c5c140a653bd761a077a7ccb78da0499"
