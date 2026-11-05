from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.database import engine
from app.observability import install_operational_handling
from app.routers import auth, health, products, tenants


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    try:
        yield
    finally:
        await engine.dispose()


app = FastAPI(title=settings.APP_NAME, lifespan=lifespan)

install_operational_handling(
    app,
    request_timeout_seconds=settings.REQUEST_TIMEOUT_SECONDS,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["X-Request-ID"],
)

app.include_router(auth.router)
app.include_router(tenants.router)
app.include_router(products.router)
app.include_router(health.router)
