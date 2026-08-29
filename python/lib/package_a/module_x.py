import hashlib

from gig_utils_storage.cache import set_cache_value, get_cache_value


def f1(cache, input):
    """Returns the SHA-256 hash of the input."""

    set_cache_value(cache, "HASH", "FIELD", "VALUE")
    state = get_cache_value(cache, "HASH", "FIELD")

    x = input | {"state": state}
    if isinstance(x, str):
        x = x.encode("utf-8")
    elif not isinstance(x, bytes):
        x = str(x).encode("utf-8")

    return hashlib.sha256(x).hexdigest()
