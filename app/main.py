"""FastAPI entrypoint for the trading service (V2).

The service assumes Flyway has already applied V1 and V2 before the API
process starts. The docker-compose file enforces that with
`depends_on: flyway: condition: service_completed_successfully`.
"""

from __future__ import annotations

import logging
import os
from typing import List, Optional

from fastapi import Depends, FastAPI, HTTPException, Query, status
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import crud
from database import get_db
from schemas import HealthResponse, TradeCreate, TradeRead, TradeUpdate

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logger = logging.getLogger("trading-api")

app = FastAPI(
    title="Trading Service",
    version="2.0.0",
    description=(
        "Teaching example (step 2 / V2): trades now carry status, fees, "
        "counterparty, and updated_at."
    ),
)


@app.get("/health", response_model=HealthResponse, tags=["system"])
def health(session: Session = Depends(get_db)) -> HealthResponse:
    """Return service health and confirm the database is reachable."""
    database_status: str = "reachable"
    try:
        session.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        logger.error("Health check DB probe failed: %s", exc)
        database_status = "unreachable"
    return HealthResponse(status="ok", database=database_status)  # type: ignore[arg-type]


@app.post(
    "/trades",
    response_model=TradeRead,
    status_code=status.HTTP_201_CREATED,
    tags=["trades"],
)
def create_trade_endpoint(
    payload: TradeCreate, session: Session = Depends(get_db)
) -> TradeRead:
    """Create a new BUY or SELL trade."""
    trade = crud.create_trade(session, payload)
    return TradeRead.model_validate(trade)


@app.get("/trades", response_model=List[TradeRead], tags=["trades"])
def list_trades_endpoint(
    symbol: Optional[str] = Query(default=None, description="Filter by ticker symbol"),
    side: Optional[str] = Query(default=None, description="Filter by BUY or SELL"),
    status_filter: Optional[str] = Query(
        default=None,
        alias="status",
        description="Filter by PENDING, SETTLED, or CANCELLED",
    ),
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
    session: Session = Depends(get_db),
) -> List[TradeRead]:
    """List trades ordered by most recently executed first."""
    trades = crud.list_trades(
        session=session,
        symbol=symbol,
        side=side,
        status=status_filter,
        limit=limit,
        offset=offset,
    )
    return [TradeRead.model_validate(trade) for trade in trades]


@app.get("/trades/{trade_id}", response_model=TradeRead, tags=["trades"])
def get_trade_endpoint(
    trade_id: int, session: Session = Depends(get_db)
) -> TradeRead:
    """Return a single trade by id."""
    trade = crud.get_trade(session, trade_id)
    if trade is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Trade {trade_id} not found",
        )
    return TradeRead.model_validate(trade)


@app.put("/trades/{trade_id}", response_model=TradeRead, tags=["trades"])
def update_trade_endpoint(
    trade_id: int,
    payload: TradeUpdate,
    session: Session = Depends(get_db),
) -> TradeRead:
    """Apply a partial update (for example, marking a trade SETTLED)."""
    trade = crud.update_trade(session, trade_id, payload)
    if trade is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Trade {trade_id} not found",
        )
    return TradeRead.model_validate(trade)


@app.delete(
    "/trades/{trade_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    tags=["trades"],
)
def delete_trade_endpoint(
    trade_id: int, session: Session = Depends(get_db)
) -> None:
    """Delete a trade by id."""
    deleted = crud.delete_trade(session, trade_id)
    if not deleted:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Trade {trade_id} not found",
        )
    return None
