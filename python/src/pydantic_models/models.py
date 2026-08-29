from pydantic import BaseModel


class RequestItemDetails(BaseModel):
    data_1: str | None = None
    data_2: str | list[str] | None = None


class ResponseItemDetails(BaseModel):
    results: str | None = None
