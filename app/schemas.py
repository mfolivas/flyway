"""Pydantic v2 request and response schemas for the trading API (V3)."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

TradeSide = Literal["BUY", "SELL"]
TradeStatus = Literal["PENDING", "SETTLED", "CANCELLED"]


class CounterpartyRead(BaseModel):
    """Response shape for GET /counterparties."""

    id: int
    name: str
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class TradeBase(BaseModel):
    """Fields shared by create and update payloads."""

    symbol: str = Field(..., min_length=1, max_length=16, examples=["AAPL"])
    side: TradeSide = Field(..., examples=["BUY"])
    quantity: Decimal = Field(..., gt=Decimal("0"), examples=["100.0000"])
    price: Decimal = Field(..., gt=Decimal("0"), examples=["189.4500"])

    @field_validator("symbol")
    @classmethod
    def _normalize_symbol(cls, value: str) -> str:
        return value.strip().upper()


class TradeCreate(TradeBase):
    """Payload accepted by POST /trades."""

    status: Optional[TradeStatus] = Field(default="PENDING")
    fees: Optional[Decimal] = Field(default=Decimal("0"), ge=Decimal("0"))
    counterparty: Optional[str] = Field(default=None, max_length=64)


class TradeUpdate(BaseModel):
    """Payload accepted by PUT /trades/{id}. Every field is optional."""

    symbol: Optional[str] = Field(default=None, min_length=1, max_length=16)
    side: Optional[TradeSide] = None
    quantity: Optional[Decimal] = Field(default=None, gt=Decimal("0"))
    price: Optional[Decimal] = Field(default=None, gt=Decimal("0"))
    status: Optional[TradeStatus] = None
    fees: Optional[Decimal] = Field(default=None, ge=Decimal("0"))
    counterparty: Optional[str] = Field(default=None, max_length=64)

    @field_validator("symbol")
    @classmethod
    def _normalize_symbol(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        return value.strip().upper()


class TradeRead(TradeBase):
    """Response returned by GET/POST/PUT endpoints."""

    id: int
    status: TradeStatus
    fees: Decimal
    counterparty: Optional[str] = None
    counterparty_id: Optional[int] = None
    executed_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class HealthResponse(BaseModel):
    """Response returned by GET /health."""

    status: Literal["ok"]
    database: Literal["reachable", "unreachable"]
