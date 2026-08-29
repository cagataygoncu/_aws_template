import json
import logging
from src.utilities import get_json
import requests

logging.basicConfig(level=logging.INFO)


def validate_api(example_requests, base_url, headers):
    responses = {}
    for key, value in example_requests.items():
        for sub_key, sub_value in value.items():
            request_data = None
            updated_url = f"{base_url}/{sub_key}{sub_value.get('parameters','')}"
            logging.info(f"Updated URL: {updated_url}")
            if key in ["PUT", "POST", "DELETE"]:
                request_data = sub_value
            response = requests.request(method=key, url=updated_url, headers=headers, data=json.dumps(request_data))
            if response.status_code != 200:
                raise ValueError(
                    f"Request failed with code: {response.status_code} and URL: {updated_url} and {key}: {sub_key}: {json.loads(response.content)} "
                )
            data = json.loads(response.text)
            response_key = f"{key.lower()}_{sub_key}"
            responses[response_key] = data
            logging.info(f"Data for {key}: {sub_key}: {json.dumps(data,indent =4)}")
    return responses


if __name__ == "__main__":
    example_requests = get_json("tests/integration/example_requests.json")
    headers = {
        "accept": "application/json",
        "X-API-Key": "NaQwVTKDrNCHLFYvQoevdHwngZiKjE",
        "Content-Type": "application/json",
    }
    # Valid Data
    base_url = "http://localhost:5040"
    responses = validate_api(example_requests, base_url, headers)
    results = {}
    results["get_protected-get"] = responses["get_protected-get"]["result"] == "task_handler-fargate"
    results["post_protected-post"] = responses["post_protected-post"]["result"] == "task_handler-fargate"

    for key, value in results.items():
        if not value:
            logging.info(f"Some API endpoints unsuccessful: {json.dumps(results,indent =4)}")
            raise ValueError(f"Response object did not pass test for response: {key} with value: {value}")
    logging.info(f"All API Endpoints testing successfully: {json.dumps(results,indent =4)}")
