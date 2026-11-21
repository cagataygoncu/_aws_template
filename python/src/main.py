import os
from enum import Enum

from gig_utils_core.logger_config import get_logger

from lib.package_a import module_x
from src.config import get_config


class Mode(Enum):
    ONLINE = "online"
    LOCAL = "local"


def get_mode():
    """Deployed code is online; a local run opts out with MODE=local.

    Online is the default so that nothing has to be set on AWS, and forgetting
    to set it locally fails loudly on the first AWS call rather than quietly
    skipping it in production.
    """
    return Mode(os.getenv("MODE", Mode.ONLINE.value).lower())


def process_request(event_data, mode=None):
    # Get logger inside function so it picks up the context set by Lambda handler
    logger = get_logger("main")

    mode = mode or get_mode()

    # The settings: the block of the config object container_config.env names,
    # with credentials from the secret (src/config.py). Read once, then cached.
    # Log what was read, never a credential or key.
    config = get_config(local=mode == Mode.LOCAL)
    logger.info(f"block {config.block}: {len(config.settings)} settings, {len(config.credentials)} credentials")

    input = {"event_data": event_data}
    logger.info(f"input: {input}")

    output = module_x.f1(input)

    logger.info(f"output: {output} for input: {input}")

    return output


if __name__ == "__main__":
    logger = get_logger("test")
    try:
        process_request("test", Mode.LOCAL)  # or MODE=local in the environment
    except Exception as ex:
        logger.exception(ex)
