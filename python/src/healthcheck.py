"""Probe this container's own health endpoint and report through the exit status.

This is what the container health check runs:

    python src/healthcheck.py

The service target's entrypoint is uvicorn, not this file, so the probe cannot
be a flag on the server the way it is in the Go and TypeScript layers - it is a
second, tiny invocation instead. It still keeps the port and the path here
rather than in a CloudFormation string, and it needs nothing in the image that
is not already there: no curl, no wget.
"""

import os
import sys
import urllib.error
import urllib.request

# The alb module's default HealthCheckPath, and the route main_server.py
# serves.
HEALTH_PATH = "/health"

# Bounds the probe. It runs inside the container against its own loopback, so
# anything slower than this is a hung process rather than a slow network.
PROBE_TIMEOUT_SECONDS = 3

# 127.0.0.1 rather than localhost: no DNS lookup, and no IPv6 attempt first in
# an image whose loopback may have no AAAA record.
PORT = os.getenv("PORT", "{{CONTAINER_PORT}}")
URL = f"http://127.0.0.1:{PORT}{HEALTH_PATH}"


def main() -> int:
    try:
        with urllib.request.urlopen(URL, timeout=PROBE_TIMEOUT_SECONDS) as response:
            if response.status != 200:
                print(f"probe {URL}: status {response.status}", file=sys.stderr)
                return 1
    except (urllib.error.URLError, OSError) as ex:
        print(f"probe {URL}: {ex}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
