"""Data-access helpers for the Trade and Counterparty resources (V3).

During the expand phase, `create_trade` writes to BOTH `trades.counterparty`
(the old string column) AND `trades.counterparty_id` (the new FK). This
keeps older readers working while new code can join through the FK.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import List, Optional

from sqlalchemy import select
from sqlalchemy.orm import Session

from models import Counterparty, Trade
from schemas import TradeCreate, TradeUpdate

logger = logging.getLogger(__name__)


def get_or_create_counterparty(session: Session, name: str) -> Counterparty:
    """Return an existing counterparty or create a new one by name."""
    normalized = name.strip()
    existing = session.execute(
        select(Counterparty).where(Counterparty.name == normalized)
    ).scalar_one_or_none()
    if existing is not None:
        return existing
    counterparty = Counterparty(name=normalized)
    session.add(counterparty)
    session.flush()
    logger.info(
        "Created counterparty id=%s name=%s", counterparty.id, counterparty.name
    )
    return counterparty


def list_counterparties(session: Session) -> List[Counterparty]:
    """Return all counterparties ordered by name."""
    return list(
        session.scalars(select(Counterparty).order_by(Counterparty.name)).all()
    )


def create_trade(session: Session, payload: TradeCreate) -> Trade:
    """Insert a new trade and return the persisted row.

    Writes both the legacy counterparty string and the normalized FK to keep
    the expand-contract migration honest.
    """
    counterparty_id: Optional[int] = None
    if payload.counterparty is not None and payload.counterparty.strip():
        counterparty_id = get_or_create_counterparty(
            session, payload.counterparty
        ).id

    trade = Trade(
        symbol=payload.symbol,
        side=payload.side,
        quantity=payload.quantity,
        price=payload.price,
        status=payload.status,
        fees=payload.fees,
        counterparty=payload.counterparty,
        counterparty_id=counterparty_id,
        updated_at=datetime.now(tz=timezone.utc),
    )
    session.add(trade)
    session.commit()
    session.refresh(trade)
    logger.info(
        "Created trade id=%s symbol=%s side=%s counterparty_id=%s",
        trade.id,
        trade.symbol,
        trade.side,
        trade.counterparty_id,
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
    """Apply a partial update to a trade. Returns None if not found.

    If `counterparty` is updated, `counterparty_id` is also resolved and set.
    """
    trade = session.get(Trade, trade_id)
    if trade is None:
        return None

    updates = payload.model_dump(exclude_unset=True)
    if "counterparty" in updates:
        cp_name = updates["counterparty"]
        if cp_name is None or not cp_name.strip():
            trade.counterparty_id = None
        else:
            trade.counterparty_id = get_or_create_counterparty(session, cp_name).id

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
