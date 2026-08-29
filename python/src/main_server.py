import sys
import json
import logging
from typing import Optional
import uvicorn
from fastapi import HTTPException, status, Security, FastAPI, Request, BackgroundTasks
from fastapi.security import APIKeyHeader, APIKeyQuery
from fastapi.responses import JSONResponse

from src.main import process_request
from src.pydantic_models.models import RequestItemDetails, ResponseItemDetails

from gig_utils_core.logger_config import setup_json_logger

logger = setup_json_logger("main")

app = FastAPI()

api_key_header = APIKeyHeader(name="X-API-Key")

api_keys = ["NaQwVTKDrNCHLFYvQoevdHwngZiKjE"]


def get_api_key(api_key_header: str = Security(api_key_header)) -> str:
    if api_key_header in api_keys:
        return api_key_header
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or missing API Key",
    )


async def aio_task_handler(request):
    response = JSONResponse({})
    try:
        response = process_request("aio_task_handler-fargate")
    except Exception as ex:
        logger.exception(ex)

    return JSONResponse(response)


def task_handler(request):
    response = JSONResponse({})
    try:
        response = process_request("task_handler-fargate")
    except Exception as ex:
        logger.exception(ex)

    return JSONResponse(response)


def background_task(data):
    pass


@app.get("/")
async def root():
    return JSONResponse({"message": "aws-service-template task is running"})


@app.get("/unprotected-get")
def unprotected_route_get(query_param1: Optional[str] = None):
    response = task_handler(query_param1)
    return response


@app.get("/unprotected-get-async")
async def aio_unprotected_route_get(request: Request, query_param1: Optional[str] = None):
    response = await aio_task_handler(query_param1)
    return response


@app.get("/protected-get")
def protected_route_get(request: Request, query_param1: Optional[str] = None, api_key: str = Security(get_api_key)):
    # Process the request for authenticated users
    response = task_handler(query_param1)
    return response


@app.post("/protected-post")
def protected_route_post(
    request: RequestItemDetails,
    background_tasks: BackgroundTasks,
    api_key: str = Security(get_api_key),
) -> ResponseItemDetails:
    """Template

    Args:
        request (ResponseItemDetails): Request object submitted to API
        api_key (str, optional): API creds. Defaults to Security(get_api_key).

    Returns:
        ResponseItemDetails: Response object returned from API
    """
    data = request.dict()
    response = task_handler(data)
    background_tasks.add_task(background_task, data)
    return response


if __name__ == "__main__":
    try:
        logger.info(f"main_server starting")
        uvicorn.run(app, host="0.0.0.0", port=5040)
    except Exception as ex:
        logger.exception(ex)
