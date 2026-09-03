import json
import os
from enum import Enum

from gig_utils_core.logger_config import get_logger
from gig_utils_security.secrets import get_secret_value
from gig_utils_storage.cache import get_cache

from lib.package_a import module_x


class Mode(Enum):
    ONLINE = "online"
    LOCAL = "local"


def get_mode():
    """Deployed code is online; a local run opts out with MODE=local.

    Online is the default so that nothing has to be set on AWS, and forgetting
    to set it locally fails loudly on the first AWS call rather than silently
    using the in-memory cache in production.
    """
    return Mode(os.getenv("MODE", Mode.ONLINE.value).lower())


def process_request(event_data, mode=None):
    # Get logger inside function so it picks up the context set by Lambda handler
    logger = get_logger("main")

    mode = mode or get_mode()

    if mode == Mode.ONLINE:
        secret_name = os.getenv("SECRET_NAME")
        redis_config = get_secret_value(secret_name)
        redis_config_json = json.loads(redis_config)
        cache = get_cache(redis_config_json, reader_only=False)
    else:
        cache = get_cache()  # use defaultdict for local testing

    input = {"event_data": event_data}
    logger.info(f"input: {input}")

    output = module_x.f1(cache, input)

    logger.info(f"output: {output} for input: {input}")

    return output


if __name__ == "__main__":
    logger = get_logger("test")
    try:
        process_request("test", Mode.LOCAL)  # or MODE=local in the environment
    except Exception as ex:
        logger.exception(ex)
