from fastapi import APIRouter

from api.core.os_context import get_os_context


router = APIRouter()


@router.get("/os/context")
async def os_context() -> dict:
    return get_os_context().to_dict()
