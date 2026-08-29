try:
    import logging

    # Configure botocore/boto3 logger levels BEFORE any imports that use them
    logging.getLogger("botocore").setLevel(logging.WARNING)
    logging.getLogger("boto3").setLevel(logging.WARNING)
    logging.getLogger("botocore.hooks").setLevel(logging.WARNING)
    logging.getLogger("botocore.credentials").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)

    from gig_utils_aws.lambda_ import generate_lambda_response, get_event_data
    from gig_utils_core.logger_config import get_logger, set_context

    from src.main import process_request
except Exception as ex:
    logging.exception(ex)


def lambda_handler_1(event, context):
    if event.get("warmup"):
        return {"statusCode": 200}

    set_context({"aws_request_id": context.aws_request_id if hasattr(context, "aws_request_id") else None})
    logger = get_logger("main")

    try:
        event_data = get_event_data(event)

        logger.debug(f"lambda_handler_1: {event=}, {context=}, {event_data=}")

        ################################################################################################
        # YOUR CODE HERE
        # Online unless MODE=local is set - see get_mode() in src/main.py.
        # Locally: make run ... RUN_ENV="MODE=local"
        output = process_request(event_data)
        ################################################################################################

        response = generate_lambda_response("lambda_handler_1", output, event, context, error=None)

        return response
    except Exception as ex:
        logger.exception("Unexpected error occurred")
        response = generate_lambda_response("lambda_handler_1", {}, event, context, error=str(ex))

        return response


if __name__ == "__main__":
    test_logger = get_logger("test")
    try:
        lambda_handler_1({"key1": "value1", "key2": "value2", "key3": "value3"}, {})
    except Exception as ex:
        test_logger.exception(ex)
