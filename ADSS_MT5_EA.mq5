#property strict
#property version   "1.0"
#property description "ADSS MT5 EA - market-driven entries, 2-second monitoring, strict Magic isolation and dynamic profit protection."

#include <Trade/Trade.mqh>
CTrade trade;

input string InpSymbols = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCHF,USDCAD,NZDUSD,EURJPY,GBPJPY,XAUUSD";
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M5;
input int    InpCheckSeconds = 2;
input long   InpMagicNumber = 826001;
input double InpRiskPerTrade = 0.01;
input int    InpMaxSpreadPoints = 40;
input int    InpATRPeriod = 14;
input int    InpEMAFast = 9;
input int    InpEMASlow = 21;
input int    InpRSIPeriod = 14;
input double InpATRSLMultiplier = 1.8;
input double InpProfitStartR = 0.6;
input double InpProfitLockR = 0.10;
input double InpTrailATRMultiplier = 1.2;
input double InpMinSignalScore = 0.55;
input bool   InpDemoOnly = true;
input int    InpDeviationPoints = 20;

string Symbols[];
string GV_PREFIX = "ADSS_EA_826001_R_";

string Trim(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}

int ParseSymbols()
{
   string raw[];
   int n = StringSplit(InpSymbols, ',', raw);
   ArrayResize(Symbols, 0);

   for(int i=0; i<n; i++)
   {
      string base = Trim(raw[i]);
      if(base == "") continue;

      string resolved = "";
      if(SymbolSelect(base, true))
         resolved = base;
      else
      {
         int total = SymbolsTotal(false);
         for(int j=0; j<total; j++)
         {
            string candidate = SymbolName(j, false);
            if(StringFind(candidate, base) == 0 && SymbolSelect(candidate, true))
            {
               resolved = candidate;
               break;
            }
         }
      }

      if(resolved != "")
      {
         int sz = ArraySize(Symbols);
         ArrayResize(Symbols, sz + 1);
         Symbols[sz] = resolved;
         Print("ADSS EA | symbol mapped: ", base, " -> ", resolved);
      }
      else
         Print("ADSS EA | symbol unavailable: ", base);
   }
   return ArraySize(Symbols);
}

bool IsOurPosition(ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;
   return (long)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber;
}

int OurPositionsOnSymbol(string symbol)
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         (long)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

bool SpreadOK(string symbol)
{
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return false;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) return false;

   return ((tick.ask - tick.bid) / point) <= InpMaxSpreadPoints;
}

bool GetATR(string symbol, double &atr)
{
   int h = iATR(symbol, InpTimeframe, InpATRPeriod);
   if(h == INVALID_HANDLE) return false;

   double buf[];
   ArraySetAsSeries(buf, true);
   bool ok = CopyBuffer(h, 0, 0, 2, buf) >= 2;
   if(ok) atr = buf[0];
   IndicatorRelease(h);
   return ok && atr > 0;
}

bool GetEMA(string symbol, int period, double &value)
{
   int h = iMA(symbol, InpTimeframe, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h == INVALID_HANDLE) return false;

   double buf[];
   ArraySetAsSeries(buf, true);
   bool ok = CopyBuffer(h, 0, 0, 1, buf) == 1;
   if(ok) value = buf[0];
   IndicatorRelease(h);
   return ok;
}

bool GetRSI(string symbol, double &value)
{
   int h = iRSI(symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(h == INVALID_HANDLE) return false;

   double buf[];
   ArraySetAsSeries(buf, true);
   bool ok = CopyBuffer(h, 0, 0, 1, buf) == 1;
   if(ok) value = buf[0];
   IndicatorRelease(h);
   return ok;
}

bool GetCurrentCandle(string symbol, MqlRates &bar)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(symbol, InpTimeframe, 0, 1, rates) != 1)
      return false;
   bar = rates[0];
   return true;
}

bool MakeSignal(string symbol, ENUM_ORDER_TYPE &direction, double &score, double &atr)
{
   double fast, slow, rsi;
   MqlRates bar;

   if(!GetEMA(symbol, InpEMAFast, fast) ||
      !GetEMA(symbol, InpEMASlow, slow) ||
      !GetRSI(symbol, rsi) ||
      !GetATR(symbol, atr) ||
      !GetCurrentCandle(symbol, bar))
      return false;

   double buy = 0.0;
   double sell = 0.0;

   if(fast > slow) buy += 1.0;
   if(rsi >= 52.0) buy += 1.0;
   if(bar.close > bar.open) buy += 1.0;

   if(fast < slow) sell += 1.0;
   if(rsi <= 48.0) sell += 1.0;
   if(bar.close < bar.open) sell += 1.0;

   buy /= 3.0;
   sell /= 3.0;

   if(buy >= InpMinSignalScore && buy > sell)
   {
      direction = ORDER_TYPE_BUY;
      score = buy;
      return true;
   }

   if(sell >= InpMinSignalScore && sell > buy)
   {
      direction = ORDER_TYPE_SELL;
      score = sell;
      return true;
   }

   return false;
}

double NormalizeVolume(string symbol, double volume)
{
   double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(vmin <= 0 || vmax <= 0 || step <= 0) return 0.0;

   volume = MathMax(vmin, MathMin(vmax, volume));
   volume = MathFloor(volume / step) * step;
   return NormalizeDouble(volume, 8);
}

double CalculateVolume(string symbol, ENUM_ORDER_TYPE direction, double entry, double sl)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPerTrade;
   if(riskMoney <= 0) return 0.0;

   double oneLotProfit = 0.0;
   if(!OrderCalcProfit(direction, symbol, 1.0, entry, sl, oneLotProfit))
      return 0.0;

   double lossPerLot = MathAbs(oneLotProfit);
   if(lossPerLot <= 0) return 0.0;

   return NormalizeVolume(symbol, riskMoney / lossPerLot);
}

bool SendEntry(string symbol, ENUM_ORDER_TYPE direction, double atr, double score)
{
   if(InpDemoOnly && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("ADSS EA | DEMO_ONLY blocked live order | ", symbol);
      return false;
   }

   if(!SpreadOK(symbol)) return false;

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return false;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double distance = atr * InpATRSLMultiplier;
   if(distance <= 0) return false;

   double entry = (direction == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   double sl = (direction == ORDER_TYPE_BUY) ? entry - distance : entry + distance;
   sl = NormalizeDouble(sl, digits);

   double volume = CalculateVolume(symbol, direction, entry, sl);
   if(volume <= 0)
   {
      Print("ADSS EA | invalid volume | ", symbol);
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(symbol);

   bool ok = false;
   if(direction == ORDER_TYPE_BUY)
      ok = trade.Buy(volume, symbol, 0.0, sl, 0.0, "ADSS_MT5_EA");
   else
      ok = trade.Sell(volume, symbol, 0.0, sl, 0.0, "ADSS_MT5_EA");

   if(ok)
   {
      ulong ticket = trade.ResultOrder();
      if(ticket > 0)
         GlobalVariableSet(GV_PREFIX + (string)ticket, MathAbs(entry - sl));

      Print("ADSS EA | ", symbol, " ",
            (direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " opened | volume=", DoubleToString(volume, 2),
            " | score=", DoubleToString(score, 2));
   }
   else
      Print("ADSS EA | order rejected | ", symbol, " | retcode=",
            trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());

   return ok;
}

double GetInitialRisk(ulong ticket, double entry, double currentSL)
{
   string key = GV_PREFIX + (string)ticket;

   if(GlobalVariableCheck(key))
      return GlobalVariableGet(key);

   if(currentSL > 0)
   {
      double r = MathAbs(entry - currentSL);
      if(r > 0)
      {
         GlobalVariableSet(key, r);
         return r;
      }
   }
   return 0.0;
}

void ProtectOurPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long type = PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) continue;

      double current = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
      double profitDistance = (type == POSITION_TYPE_BUY)
                              ? current - entry
                              : entry - current;

      double initialR = GetInitialRisk(ticket, entry, currentSL);
      if(initialR <= 0 || profitDistance < initialR * InpProfitStartR)
         continue;

      double atr;
      if(!GetATR(symbol, atr)) continue;

      double lock = initialR * InpProfitLockR;
      double trail = atr * InpTrailATRMultiplier;
      double desired;

      if(type == POSITION_TYPE_BUY)
      {
         desired = MathMax(entry + lock, current - trail);
         if(currentSL > 0 && desired <= currentSL) continue;
      }
      else
      {
         desired = MathMin(entry - lock, current + trail);
         if(currentSL > 0 && desired >= currentSL) continue;
      }

      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      desired = NormalizeDouble(desired, digits);

      trade.SetExpertMagicNumber(InpMagicNumber);
      if(trade.PositionModify(ticket, desired, tp))
         Print("ADSS EA | ", symbol, " | profit protection SL -> ",
               DoubleToString(desired, digits));
      else
         Print("ADSS EA | SL modify failed | ", symbol, " | ",
               trade.ResultRetcodeDescription());
   }
}

void ScanEntries()
{
   for(int i=0; i<ArraySize(Symbols); i++)
   {
      string symbol = Symbols[i];

      // Strict isolation: manual trades and other EAs are ignored.
      if(OurPositionsOnSymbol(symbol) > 0)
         continue;

      ENUM_ORDER_TYPE direction;
      double score, atr;

      if(MakeSignal(symbol, direction, score, atr))
         SendEntry(symbol, direction, atr, score);
   }
}

int OnInit()
{
   if(InpCheckSeconds < 1)
      return INIT_PARAMETERS_INCORRECT;

   ParseSymbols();
   if(ArraySize(Symbols) == 0)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagicNumber);
   EventSetTimer(InpCheckSeconds);

   Print("ADSS EA | STARTED | magic=", InpMagicNumber,
         " | check=", InpCheckSeconds, "s | demo_only=",
         (InpDemoOnly ? "true" : "false"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("ADSS EA | STOPPED | reason=", reason);
}

void OnTimer()
{
   ProtectOurPositions();
   ScanEntries();
}
