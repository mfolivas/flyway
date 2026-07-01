"""SQLAlchemy ORM models for the trading service.

At V2 the trades table gains lifecycle metadata: status, fees,
counterparty, and updated_at. See db/migrations/V2__enhance_trading_table.sql
for the exact DDL.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal

from sqlalchemy import BigInteger, DateTime, Index, Numeric, String, func
from sqlalchemy.orm import Mapped, mapped_column

from database import Base


class Trade(Base):
    """A single buy or sell transaction for a security."""

    __tablename__ = "trades"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    symbol: Mapped[str] = mapped_column(String(16), nullable=False)
    side: Mapped[str] = mapped_column(String(4), nullable=False)
    quantity: Mapped[Decimal] = mapped_column(Numeric(20, 4), nullable=False)
    price: Mapped[Decimal] = mapped_column(Numeric(20, 4), nullable=False)
    executed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    # Introduced in V2. NOT NULL in the database with server-side defaults, so
    # the ORM can omit them on insert and Postgres fills them in.
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, server_default="PENDING"
    )
    fees: Mapped[Decimal] = mapped_column(
        Numeric(20, 4), nullable=False, server_default="0"
    )
    counterparty: Mapped[str | None] = mapped_column(String(64), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    __table_args__ = (
        Index("ix_trades_symbol", "symbol"),
        Index("ix_trades_status", "status"),
    )
