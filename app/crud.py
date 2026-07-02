"""Data-access helpers for the Trade resource.

Post-V4 rollback of V3: writes and reads no longer touch a
`counterparty_id` FK or a `counterparties` table. `counterparty` is a
plain string column on `trades` again.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import List, Optional

from sqlalchemy import select
from sqlalchemy.orm import Session

from models import Trade
from schemas import TradeCreate, TradeUpdate

logger = logging.getLogger(__name__)


def create_trade(session: Session, payload: TradeCreate) -> Trade:
    """Insert a new trade and return the persisted row."""
    trade = Trade(
        symbol=payload.symbol,
        side=payload.side,
        quantity=payload.quantity,
        price=payload.price,
        status=payload.status,
        fees=payload.fees,
        counterparty=payload.counterparty,
        updated_at=datetime.now(tz=timezone.utc),
    )
    session.add(trade)
    session.commit()
    session.refresh(trade)
    logger.info(
        "Created trade id=%s symbol=%s side=%s status=%s",
        trade.id,
        trade.symbol,
        trade.side,
        trade.status,
    )
    return trade


def get_trade(session: Session, trade_id: int) -> Optional[Trade]:
    """Return a single trade by primary key, or None if it does not exist."""
    return session.get(Trade, trade_id)


def list_trades(
    session: Session,
    symbol: Optional[str] = None,
    side: Optional[str] = None,
    status: Optional[str] = None,
    limit: int = 100,
    offset: int = 0,
) -> List[Trade]:
    """Return trades matching the optional filters, newest first."""
    statement = select(Trade)
    if symbol is not None:
        statement = statement.where(Trade.symbol == symbol.strip().upper())
    if side is not None:
        statement = statement.where(Trade.side == side.upper())
    if status is not None:
        statement = statement.where(Trade.status == status.upper())

    statement = statement.order_by(Trade.executed_at.desc()).limit(limit).offset(offset)
    return list(session.scalars(statement).all())


def update_trade(
    session: Session, trade_id: int, payload: TradeUpdate
) -> Optional[Trade]:
    """Apply a partial update to a trade. Returns None if not found."""
    trade = session.get(Trade, trade_id)
    if trade is None:
        return None

    updates = payload.model_dump(exclude_unset=True)
    for field, value in updates.items():
        setattr(trade, field, value)
    trade.updated_at = datetime.now(tz=timezone.utc)

    session.commit()
    session.refresh(trade)
    logger.info("Updated trade id=%s fields=%s", trade.id, sorted(updates.keys()))
    return trade


def delete_trade(session: Session, trade_id: int) -> bool:
    """Delete a trade by id. Returns True if a row was deleted, else False."""
    trade = session.get(Trade, trade_id)
    if trade is None:
        return False
    session.delete(trade)
    session.commit()
    logger.info("Deleted trade id=%s", trade_id)
    return True
