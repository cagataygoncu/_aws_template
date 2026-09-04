import sys
import time

from gig_utils_core.logger_config import setup_json_logger

from src.main import process_request

logger = setup_json_logger("main")

if __name__ == "__main__":
    # Two try blocks, doing different jobs.
    #
    # The outer one catches anything that goes wrong before or around the loop
    # - a missing environment variable, a failed client construction - logs the
    # traceback and exits non-zero. Without it the container dies with only a
    # bare stack trace on stderr, or nothing at all, and `make local-run` can report
    # no more than "exited (1)".
    try:
        logger.info("main_task starting")

        # The inner one sits inside the loop on purpose: this is a long-running
        # ECS service, so one failed iteration must not end the process. A
        # container that exits is a stopped task, and enough stopped tasks trip
        # the deployment circuit breaker and roll the whole deploy back.
        while True:
            try:
                logger.info("processing")
                process_request("test")
            except Exception as ex:
                logger.exception(ex)

            time.sleep(3)
    except Exception as ex:
        logger.exception(ex)
        sys.exit(1)
