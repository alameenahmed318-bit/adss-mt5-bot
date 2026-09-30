import os
import time
import math
import logging
from dataclasses import dataclass

import MetaTrader5 as mt5
import numpy as np
import pandas as pd
from dotenv import load_dotenv

load_dotenv()

CHECK_INTERVAL = float(os.getenv("CHECK_INTERVAL_SECONDS", "2"))
MAGIC = int(os.getenv("MAGIC_NUMBER", "826001"))
RISK = float(os.getenv("RISK_PER_TRADE", "0.01"))
MAX_SPREAD_POINTS = float(os.getenv("MAX_SPREAD_POINTS", "40"))
ATR_PERIOD = int(os.getenv("ATR_PERIOD", "14"))
EMA_FAST = int(os.getenv("EMA_FAST", "9"))
EMA_SLOW = int(os.getenv("EMA_SLOW", "21"))
RSI_PERIOD = int(os.getenv("RSI_PERIOD", "14"))
ATR_SL = float(os.getenv("ATR_SL_MULTIPLIER", "1.8"))
PROFIT_START_R = float(os.getenv("PROFIT_START_R", "0.6"))
PROFIT_LOCK_R = float(os.getenv("PROFIT_LOCK_R", "0.10"))
TRAIL_ATR = float(os.getenv("TRAIL_ATR_MULTIPLIER", "1.2"))
MIN_SCORE = float(os.getenv("MIN_SIGNAL_SCORE", "0.55"))
DEMO_ONLY = os.getenv("DEMO_ONLY", "true").lower() == "true"
TIMEFRAME_NAME = os.getenv("TIMEFRAME", "M5").upper()
SYMBOLS = [s.strip() for s in os.getenv(
    "MT5_SYMBOLS",
    "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCHF,USDCAD,NZDUSD,EURJPY,GBPJPY,XAUUSD"
).split(",") if s.strip()]

TIMEFRAMES = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
}
TIMEFRAME = TIMEFRAMES.get(TIMEFRAME_NAME, mt5.TIMEFRAME_M5)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | ADSS-MT5 | %(levelname)s | %(message)s",
)

@dataclass
class Signal:
    direction: str
    score: float
    atr: float

def rates(symbol, count=120):
    data = mt5.copy_rates_from_pos(symbol, TIMEFRAME, 0, count)
    if data is None or len(data) < max(EMA_SLOW + 10, ATR_PERIOD + 10):
        return None
    df = pd.DataFrame(data)
    df["ema_fast"] = df["close"].ewm(span=EMA_FAST, adjust=False).mean()
    df["ema_slow"] = df["close"].ewm(span=EMA_SLOW, adjust=False).mean()
    delta = df["close"].diff()
    gain = delta.clip(lower=0).rolling(RSI_PERIOD).mean()
    loss = (-delta.clip(upper=0)).rolling(RSI_PERIOD).mean()
    rs = gain / loss.replace(0, np.nan)
    df["rsi"] = 100 - (100 / (1 + rs))
    prev = df["close"].shift(1)
    tr = pd.concat([
        df["high"] - df["low"],
        (df["high"] - prev).abs(),
        (df["low"] - prev).abs(),
    ], axis=1).max(axis=1)
    df["atr"] = tr.rolling(ATR_PERIOD).mean()
    return df.dropna()

def owned_positions(symbol=None):
    positions = mt5.positions_get(symbol=symbol) if symbol else mt5.positions_get()
    return [p for p in (positions or []) if int(getattr(p, "magic", -1)) == MAGIC]

def spread_ok(symbol):
    tick = mt5.symbol_info_tick(symbol)
    info = mt5.symbol_info(symbol)
    if not tick or not info:
        return False, None
    spread = (tick.ask - tick.bid) / info.point
    return spread <= MAX_SPREAD_POINTS, spread

def make_signal(symbol):
    df = rates(symbol)
    if df is None:
        return None
    a, b = df.iloc[-2], df.iloc[-1]
    if a.atr <= 0:
        return None

    buy = sum([
        b.ema_fast > b.ema_slow,
        b.rsi >= 52,
        b.close > b.open,
    ]) / 3.0
    sell = sum([
        b.ema_fast < b.ema_slow,
        b.rsi <= 48,
        b.close < b.open,
    ]) / 3.0

    if buy >= MIN_SCORE and buy > sell:
        return Signal("BUY", float(buy), float(b.atr))
    if sell >= MIN_SCORE and sell > buy:
        return Signal("SELL", float(sell), float(b.atr))
    return None

def normalize_volume(symbol, volume):
    info = mt5.symbol_info(symbol)
    if not info:
        return 0.0
    step = info.volume_step or 0.01
    volume = max(info.volume_min, min(info.volume_max, volume))
    return math.floor(volume / step) * step

def position_size(symbol, stop_distance):
    account = mt5.account_info()
    info = mt5.symbol_info(symbol)
    if not account or not info or stop_distance <= 0:
        return 0.0
    tick_size = info.trade_tick_size
    tick_value = info.trade_tick_value
    if not tick_size or not tick_value:
        return 0.0
    risk_money = float(account.equity) * RISK
    loss_per_lot = (stop_distance / tick_size) * tick_value
    if loss_per_lot <= 0:
        return 0.0
    return normalize_volume(symbol, risk_money / loss_per_lot)

def send_order(symbol, signal):
    account = mt5.account_info()
    if DEMO_ONLY and (
        not account or account.trade_mode != mt5.ACCOUNT_TRADE_MODE_DEMO
    ):
        logging.error("%s | DEMO_ONLY blocked this order", symbol)
        return False

    ok, spread = spread_ok(symbol)
    if not ok:
        logging.info("%s | spread too high: %.1f points", symbol, spread or -1)
        return False

    info = mt5.symbol_info(symbol)
    tick = mt5.symbol_info_tick(symbol)
    if not info or not tick:
        return False

    distance = signal.atr * ATR_SL
    volume = position_size(symbol, distance)
    if volume <= 0:
        return False

    if signal.direction == "BUY":
        order_type = mt5.ORDER_TYPE_BUY
        price = tick.ask
        sl = price - distance
    else:
        order_type = mt5.ORDER_TYPE_SELL
        price = tick.bid
        sl = price + distance

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": volume,
        "type": order_type,
        "price": price,
        "sl": sl,
        "deviation": 20,
        "magic": MAGIC,
        "comment": "ADSS_MT5_BOT",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": info.filling_mode,
    }
    result = mt5.order_send(request)
    if result and result.retcode == mt5.TRADE_RETCODE_DONE:
        logging.info("%s | %s opened | volume=%.2f | score=%.2f",
                     symbol, signal.direction, volume, signal.score)
        return True
    logging.warning("%s | order rejected: %s", symbol, getattr(result, "retcode", None))
    return False

def protect_profit():
    for p in owned_positions():
        info = mt5.symbol_info(p.symbol)
        tick = mt5.symbol_info_tick(p.symbol)
        if not info or not tick:
            continue

        current = tick.bid if p.type == mt5.POSITION_TYPE_BUY else tick.ask
        entry = float(p.price_open)
        profit_distance = (
            current - entry if p.type == mt5.POSITION_TYPE_BUY
            else entry - current
        )
        initial_r = abs(entry - float(p.sl)) if p.sl else 0.0
        if initial_r <= 0 or profit_distance < initial_r * PROFIT_START_R:
            continue

        df = rates(p.symbol, 80)
        if df is None:
            continue
        atr = float(df.iloc[-1].atr)
        lock = initial_r * PROFIT_LOCK_R
        trail = atr * TRAIL_ATR

        if p.type == mt5.POSITION_TYPE_BUY:
            desired = max(entry + lock, current - trail)
            if p.sl and desired <= p.sl + info.point:
                continue
        else:
            desired = min(entry - lock, current + trail)
            if p.sl and desired >= p.sl - info.point:
                continue

        request = {
            "action": mt5.TRADE_ACTION_SLTP,
            "position": p.ticket,
            "symbol": p.symbol,
            "sl": desired,
            "tp": p.tp,
            "magic": MAGIC,
            "comment": "ADSS_PROFIT_PROTECT",
        }
        result = mt5.order_send(request)
        if result and result.retcode == mt5.TRADE_RETCODE_DONE:
            logging.info("%s | profit protection moved SL to %.5f",
                         p.symbol, desired)

def initialize():
    path = os.getenv("MT5_PATH", "").strip()
    kwargs = {"path": path} if path else {}
    if not mt5.initialize(**kwargs):
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")

    account = mt5.account_info()
    if not account:
        raise RuntimeError("MT5 account unavailable")

    logging.info(
        "Connected | login=%s | server=%s | balance=%.2f | trade_mode=%s",
        account.login, account.server, account.balance, account.trade_mode
    )

    for symbol in SYMBOLS:
        if not mt5.symbol_select(symbol, True):
            logging.warning("%s | symbol unavailable; skipped", symbol)

def main():
    initialize()
    logging.info(
        "Started | check=%ss | magic=%s | demo_only=%s",
        CHECK_INTERVAL, MAGIC, DEMO_ONLY
    )
    try:
        while True:
            # Protection is checked every cycle.
            protect_profit()

            for symbol in SYMBOLS:
                # This only counts OUR positions.
                if owned_positions(symbol):
                    continue
                signal = make_signal(symbol)
                if signal:
                    send_order(symbol, signal)

            time.sleep(CHECK_INTERVAL)
    finally:
        mt5.shutdown()

if __name__ == "__main__":
    main()
