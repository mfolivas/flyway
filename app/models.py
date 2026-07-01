"""SQLAlchemy ORM models for the trading service.

At V3 counterparties become a first-class table. Trades gain a nullable
foreign key `counterparty_id`. During the expand phase both the old
`trades.counterparty` string column AND the new FK are present, so older
consumers can keep reading the string form until V4 removes it.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Optional

from sqlalchemy import (
    BigInteger,
    DateTime,
    ForeignKey,
    Index,
    Numeric,
    String,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from database import Base


class Counterparty(Base):
    """The other side of a trade. Introduced in V3."""

    __tablename__ = "counterparties"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


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

    status: Mapped[str] = mapped_column(
        String(16), nullable=False, server_default="PENDING"
    )
    fees: Mapped[Decimal] = mapped_column(
        Numeric(20, 4), nullable=False, server_default="0"
    )
    counterparty: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    # V3: nullable foreign key. Populated on create when a counterparty name
    # is supplied. The old string column above is kept in place for expand.
    # An SQLAlchemy relationship on this FK is intentionally omitted -
    # nothing in the API surface reads the joined Counterparty object, so
    # a relationship would only add overhead and confuse the reader.
    counterparty_id: Mapped[Optional[int]] = mapped_column(
        BigInteger, ForeignKey("counterparties.id"), nullable=True
    )

    __table_args__ = (
        Index("ix_trades_symbol", "symbol"),
        Index("ix_trades_status", "status"),
        Index("ix_trades_counterparty_id", "counterparty_id"),
    )
