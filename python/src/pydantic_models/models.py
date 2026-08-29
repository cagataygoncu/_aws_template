from typing import Optional, Union
from pydantic import BaseModel


class RequestItemDetails(BaseModel):
    data_1: Optional[str] = None
    data_2: Optional[Union[str, list[str]]] = None

class ResponseItemDetails(BaseModel):
    results: Optional[str] = None

