# ADSS MT5 Bot

Demo-first MetaTrader 5 bot for ADSS MT5.

- Market scan and position protection every 2 seconds.
- Demo-only by default.
- Every order uses a unique Magic Number.
- Position management filters by Magic Number, so manual/other-bot positions are not modified.
- ATR-based stop and dynamic profit protection.
- Risk-based position sizing.
- Credentials are not stored in the repository.

Requirements: Windows + MT5 terminal logged into ADSS + Python 3.11+.
Install: pip install -r requirements.txt
Run: python bot.py

Keep DEMO_ONLY=true until the strategy is tested on ADSS Demo. No profitability guarantee.
