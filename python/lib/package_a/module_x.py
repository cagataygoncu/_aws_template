import hashlib


def f1(input):
    """Returns the SHA-256 hash of the input."""

    x = input
    if isinstance(x, str):
        x = x.encode("utf-8")
    elif not isinstance(x, bytes):
        x = str(x).encode("utf-8")

    return hashlib.sha256(x).hexdigest()
