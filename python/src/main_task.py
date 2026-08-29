import time

from gig_utils_core.logger_config import setup_json_logger

from src.main import process_request

logger = setup_json_logger("main")

if __name__ == "__main__":
    try:
        logger.info(f"main_task starting")

        while True:
            logger.info(f"processing")
            process_request("test")
            time.sleep(3)
    except Exception as ex:
        logger.exception(ex)
