from pathlib import Path

import uvicorn
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from api.config import get_settings
from api.routes.os_context import router as os_context_router
from api.routes.permissions import router as permissions_router
from api.routes.runs import router as runs_router


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="klo", version="0.1.0")
    app.include_router(runs_router)
    app.include_router(permissions_router)
    app.include_router(os_context_router)

    settings.artifacts_dir.mkdir(parents=True, exist_ok=True)
    app.mount(
        "/artifacts",
        StaticFiles(directory=settings.artifacts_dir, html=False),
        name="artifacts",
    )

    web_dir = Path(__file__).resolve().parent.parent / "web"
    if web_dir.exists():
        app.mount("/", StaticFiles(directory=web_dir, html=True), name="web")

    return app


app = create_app()


def main() -> None:
    settings = get_settings()
    uvicorn.run("api.main:app", host=settings.host, port=settings.port, reload=False)


if __name__ == "__main__":
    main()
