//+------------------------------------------------------------------+
//|                                     EMA_Pullback_Trading_Bot.mq5 |
//|                           EMA Trend Pullback Strategy Expert Advisor|
//|                                                                    |
//|  Strategy: Wait for EMA20/EMA50 crossover on M1, then trade the   |
//|  third pullback into the EMA zone when all three timeframes (M15,  |
//|  M5, M1) agree on trend direction.                                 |
//+------------------------------------------------------------------+
#property copyright   "EMA Pullback Trading Bot"
#property version     "1.00"
#property description "EMA Trend Pullback Strategy EA for MetaTrader 5"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+
input group "=== Trade Settings ==="
input double   InpLotSize            = 0.02;   // Lot Size (hard limit: 0.02)
input double   InpRiskRewardRatio    = 2.0;    // Risk:Reward Ratio (1–4)
input int      InpSlippage           = 3;      // Slippage (points)
input ulong    InpMagicNumber        = 123456; // Magic Number
input bool     InpTrailingStopEnabled= true;   // Enable Trailing Stop

input group "=== EMA Settings ==="
input int      InpEMAFastPeriod      = 20;     // EMA Fast Period
input int      InpEMASlowPeriod      = 50;     // EMA Slow Period
input double   InpEMABufferPoints    = 3.0;    // EMA Buffer Distance (points)

//+------------------------------------------------------------------+
//| Constants                                                          |
//+------------------------------------------------------------------+
#define MAX_LOT_SIZE      0.02
#define MIN_RR_RATIO      1.0
#define MAX_RR_RATIO      4.0
#define PULLBACK_THRESHOLD 3      // Number of pullbacks required before entry
#define EMA_BUFFER_SIZE   3      // CopyBuffer bars to retrieve (current + 2 history bars)

//+------------------------------------------------------------------+
//| Global Variables – Indicator Handles                               |
//+------------------------------------------------------------------+
// M1 handles
int g_emaFastHandleM1  = INVALID_HANDLE;
int g_emaSlowHandleM1  = INVALID_HANDLE;
// M5 handles
int g_emaFastHandleM5  = INVALID_HANDLE;
int g_emaSlowHandleM5  = INVALID_HANDLE;
// M15 handles
int g_emaFastHandleM15 = INVALID_HANDLE;
int g_emaSlowHandleM15 = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Global Variables – Strategy State                                  |
//+------------------------------------------------------------------+
// Trend direction: +1 = uptrend, -1 = downtrend, 0 = no trend
int    g_trendDirection     = 0;

// Crossover detected flag (first crossover after which we start watching)
bool   g_crossoverDetected  = false;

// Pullback counter (resets when a new crossover is detected)
int    g_pullbackCount      = 0;

// Flag: whether price is currently inside the EMA zone
bool   g_inEMAZone          = false;

// Last bar time processed (to avoid re-processing same bar)
datetime g_lastBarTime      = 0;

// Trade object
CTrade g_trade;

//+------------------------------------------------------------------+
//| Expert Advisor initialization                                      |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate input parameters
   if(InpLotSize > MAX_LOT_SIZE)
   {
      Print("ERROR: LotSize (", InpLotSize, ") exceeds maximum allowed (", MAX_LOT_SIZE, "). EA will not run.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpRiskRewardRatio < MIN_RR_RATIO || InpRiskRewardRatio > MAX_RR_RATIO)
   {
      Print("ERROR: RiskRewardRatio (", InpRiskRewardRatio, ") out of range [", MIN_RR_RATIO, ",", MAX_RR_RATIO, "]. EA will not run.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpEMAFastPeriod <= 0 || InpEMASlowPeriod <= 0 || InpEMAFastPeriod >= InpEMASlowPeriod)
   {
      Print("ERROR: Invalid EMA periods. Fast (", InpEMAFastPeriod, ") must be positive and less than Slow (", InpEMASlowPeriod, ").");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Configure trade object
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize all indicator handles
   if(!InitializeIndicators())
   {
      Print("ERROR: Failed to initialize indicators. EA will not run.");
      return INIT_FAILED;
   }

   Print("EMA Pullback Trading Bot initialized successfully.");
   Print("Symbol: ", _Symbol, " | Magic: ", InpMagicNumber,
         " | Lot: ", InpLotSize, " | RR: ", InpRiskRewardRatio,
         " | EMA Fast: ", InpEMAFastPeriod, " | EMA Slow: ", InpEMASlowPeriod);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert Advisor deinitialization                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release all indicator handles to free resources
   if(g_emaFastHandleM1  != INVALID_HANDLE) IndicatorRelease(g_emaFastHandleM1);
   if(g_emaSlowHandleM1  != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandleM1);
   if(g_emaFastHandleM5  != INVALID_HANDLE) IndicatorRelease(g_emaFastHandleM5);
   if(g_emaSlowHandleM5  != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandleM5);
   if(g_emaFastHandleM15 != INVALID_HANDLE) IndicatorRelease(g_emaFastHandleM15);
   if(g_emaSlowHandleM15 != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandleM15);

   Print("EMA Pullback Trading Bot deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert Advisor main tick function                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only process logic on new M1 bar (bar-open logic to avoid re-entry)
   datetime currentBarTime = iTime(_Symbol, PERIOD_M1, 0);
   if(currentBarTime == g_lastBarTime)
   {
      // Within the same bar: only manage trailing stop for open positions
      if(InpTrailingStopEnabled && PositionExists())
         ManageTrailingStop();
      return;
   }
   g_lastBarTime = currentBarTime;

   // Step 1: Retrieve current EMA values for all timeframes
   double emaFastM1 = 0.0, emaSlowM1 = 0.0;
   double emaFastM5 = 0.0, emaSlowM5 = 0.0;
   double emaFastM15 = 0.0, emaSlowM15 = 0.0;
   double emaFastM1Prev = 0.0, emaSlowM1Prev = 0.0;

   if(!GetEMAValues(g_emaFastHandleM1,  emaFastM1,  emaFastM1Prev))  return;
   if(!GetEMAValues(g_emaSlowHandleM1,  emaSlowM1,  emaSlowM1Prev))  return;
   if(!GetEMAValuesM5(emaFastM5, emaSlowM5))                          return;
   if(!GetEMAValuesM15(emaFastM15, emaSlowM15))                       return;

   // Step 2: Multi-timeframe trend confirmation
   int trendNow = CheckTrendMTF(emaFastM1, emaSlowM1,
                                 emaFastM5, emaSlowM5,
                                 emaFastM15, emaSlowM15);

   // If trend direction changed, reset state
   if(trendNow != g_trendDirection)
   {
      g_trendDirection    = trendNow;
      g_crossoverDetected = false;
      g_pullbackCount     = 0;
      g_inEMAZone         = false;
   }

   // No trading without a confirmed trend
   if(g_trendDirection == 0) return;

   // Step 3: Detect first crossover on M1
   if(!g_crossoverDetected)
   {
      if(DetectCrossover(emaFastM1, emaSlowM1, emaFastM1Prev, emaSlowM1Prev, g_trendDirection))
      {
         g_crossoverDetected = true;
         g_pullbackCount     = 0;
         g_inEMAZone         = false;
         Print("Crossover detected. Trend direction: ", g_trendDirection,
               ". Waiting for pullbacks.");
      }
      return; // Do not trade until crossover is confirmed
   }

   // Step 4: Count pullback touches into the EMA zone
   double closePrice = iClose(_Symbol, PERIOD_M1, 1); // Use closed bar
   CountPullbacks(closePrice, emaFastM1, emaSlowM1);

   // Step 5: Check entry conditions and trade if all criteria met
   if(!PositionExists())
   {
      if(CheckEntryConditions(closePrice, emaFastM1, emaSlowM1))
      {
         if(g_trendDirection == 1)
            OpenBuyTrade(emaFastM1, emaSlowM1);
         else if(g_trendDirection == -1)
            OpenSellTrade(emaFastM1, emaSlowM1);

         // Reset pullback count after trade entry
         g_pullbackCount = 0;
         g_inEMAZone     = false;
      }
   }

   // Step 6: Manage trailing stop for open positions
   if(InpTrailingStopEnabled && PositionExists())
      ManageTrailingStop();
}

//+------------------------------------------------------------------+
//| InitializeIndicators                                               |
//| Creates EMA indicator handles for M1, M5, and M15 timeframes.     |
//+------------------------------------------------------------------+
bool InitializeIndicators()
{
   // M1 EMA handles
   g_emaFastHandleM1 = iMA(_Symbol, PERIOD_M1, InpEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaFastHandleM1 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA Fast handle for M1. Error: ", GetLastError());
      return false;
   }

   g_emaSlowHandleM1 = iMA(_Symbol, PERIOD_M1, InpEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaSlowHandleM1 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA Slow handle for M1. Error: ", GetLastError());
      return false;
   }

   // M5 EMA handles
   g_emaFastHandleM5 = iMA(_Symbol, PERIOD_M5, InpEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaFastHandleM5 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA Fast handle for M5. Error: ", GetLastError());
      return false;
   }

   g_emaSlowHandleM5 = iMA(_Symbol, PERIOD_M5, InpEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaSlowHandleM5 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA Slow handle for M5. Error: ", GetLastError());
      return false;
   }

   // M15 EMA handles
   g_emaFastHandleM15 = iMA(_Symbol, PERIOD_M15, InpEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaFastHandleM15 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA Fast handle for M15. Error: ", GetLastError());
      return false;
   }

   g_emaSlowHandleM15 = iMA(_Symbol, PERIOD_M15, InpEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaSlowHandleM15 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA Slow handle for M15. Error: ", GetLastError());
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| GetEMAValues                                                       |
//| Copies the two most recent values from an EMA indicator handle.    |
//| Returns false if CopyBuffer fails.                                 |
//+------------------------------------------------------------------+
bool GetEMAValues(const int handle, double &valueCurrent, double &valuePrev)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);

   if(CopyBuffer(handle, 0, 0, EMA_BUFFER_SIZE, buffer) < EMA_BUFFER_SIZE)
   {
      Print("ERROR: CopyBuffer failed for handle ", handle, ". Error: ", GetLastError());
      return false;
   }

   valueCurrent = buffer[1]; // Index 1 = last closed bar
   valuePrev    = buffer[2]; // Index 2 = bar before last closed bar
   return true;
}

//+------------------------------------------------------------------+
//| GetEMAValuesM5                                                     |
//| Returns EMA fast and slow values for M5 timeframe (last closed bar)|
//+------------------------------------------------------------------+
bool GetEMAValuesM5(double &emaFast, double &emaSlow)
{
   double bufFast[], bufSlow[];
   ArraySetAsSeries(bufFast, true);
   ArraySetAsSeries(bufSlow, true);

   if(CopyBuffer(g_emaFastHandleM5, 0, 0, EMA_BUFFER_SIZE, bufFast) < EMA_BUFFER_SIZE)
   {
      Print("ERROR: CopyBuffer failed for M5 EMA Fast. Error: ", GetLastError());
      return false;
   }
   if(CopyBuffer(g_emaSlowHandleM5, 0, 0, EMA_BUFFER_SIZE, bufSlow) < EMA_BUFFER_SIZE)
   {
      Print("ERROR: CopyBuffer failed for M5 EMA Slow. Error: ", GetLastError());
      return false;
   }

   emaFast = bufFast[1];
   emaSlow = bufSlow[1];
   return true;
}

//+------------------------------------------------------------------+
//| GetEMAValuesM15                                                    |
//| Returns EMA fast and slow values for M15 timeframe (last closed bar)|
//+------------------------------------------------------------------+
bool GetEMAValuesM15(double &emaFast, double &emaSlow)
{
   double bufFast[], bufSlow[];
   ArraySetAsSeries(bufFast, true);
   ArraySetAsSeries(bufSlow, true);

   if(CopyBuffer(g_emaFastHandleM15, 0, 0, EMA_BUFFER_SIZE, bufFast) < EMA_BUFFER_SIZE)
   {
      Print("ERROR: CopyBuffer failed for M15 EMA Fast. Error: ", GetLastError());
      return false;
   }
   if(CopyBuffer(g_emaSlowHandleM15, 0, 0, EMA_BUFFER_SIZE, bufSlow) < EMA_BUFFER_SIZE)
   {
      Print("ERROR: CopyBuffer failed for M15 EMA Slow. Error: ", GetLastError());
      return false;
   }

   emaFast = bufFast[1];
   emaSlow = bufSlow[1];
   return true;
}

//+------------------------------------------------------------------+
//| CheckTrendMTF                                                      |
//| Confirms trend direction across M15, M5, and M1 timeframes.       |
//| Returns: +1 for uptrend, -1 for downtrend, 0 for no consensus.    |
//+------------------------------------------------------------------+
int CheckTrendMTF(const double emaFastM1,  const double emaSlowM1,
                  const double emaFastM5,  const double emaSlowM5,
                  const double emaFastM15, const double emaSlowM15)
{
   bool uptrendM1  = (emaFastM1  > emaSlowM1);
   bool uptrendM5  = (emaFastM5  > emaSlowM5);
   bool uptrendM15 = (emaFastM15 > emaSlowM15);

   if(uptrendM1 && uptrendM5 && uptrendM15)
      return 1;  // All three timeframes confirm uptrend

   if(!uptrendM1 && !uptrendM5 && !uptrendM15)
      return -1; // All three timeframes confirm downtrend

   return 0; // Mixed signals – no trade allowed
}

//+------------------------------------------------------------------+
//| DetectCrossover                                                    |
//| Detects the FIRST EMA20/EMA50 crossover on M1 for a given trend.  |
//| Returns true when the crossover matching trendDir is found.        |
//+------------------------------------------------------------------+
bool DetectCrossover(const double emaFastCurrent, const double emaSlowCurrent,
                     const double emaFastPrev,    const double emaSlowPrev,
                     const int trendDir)
{
   // Bullish crossover: EMA fast crossed above EMA slow
   if(trendDir == 1)
   {
      if(emaFastPrev <= emaSlowPrev && emaFastCurrent > emaSlowCurrent)
         return true;
   }
   // Bearish crossover: EMA fast crossed below EMA slow
   else if(trendDir == -1)
   {
      if(emaFastPrev >= emaSlowPrev && emaFastCurrent < emaSlowCurrent)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| CountPullbacks                                                     |
//| Tracks entries into the EMA zone (between EMA20 and EMA50).       |
//| Each time price enters the zone from outside, pullbackCount++.     |
//+------------------------------------------------------------------+
void CountPullbacks(const double closePrice,
                    const double emaFast,
                    const double emaSlow)
{
   double zoneHigh = MathMax(emaFast, emaSlow);
   double zoneLow  = MathMin(emaFast, emaSlow);

   bool insideZone = (closePrice >= zoneLow && closePrice <= zoneHigh);

   if(insideZone && !g_inEMAZone)
   {
      // Price just entered the EMA zone – count this as a pullback touch
      g_pullbackCount++;
      g_inEMAZone = true;
      Print("Pullback touch #", g_pullbackCount, " detected. Price: ", closePrice,
            " | EMA zone: [", zoneLow, " – ", zoneHigh, "]");
   }
   else if(!insideZone)
   {
      // Price has exited the zone; allow another entry count next time
      g_inEMAZone = false;
   }
}

//+------------------------------------------------------------------+
//| CheckEntryConditions                                               |
//| Returns true when all entry criteria are satisfied:                |
//| - Crossover has been detected                                      |
//| - Pullback count has reached the threshold (3rd touch)             |
//| - Price is currently inside the EMA zone                           |
//+------------------------------------------------------------------+
bool CheckEntryConditions(const double closePrice,
                          const double emaFast,
                          const double emaSlow)
{
   if(!g_crossoverDetected)
      return false;

   if(g_pullbackCount < PULLBACK_THRESHOLD)
      return false;

   // Price must be inside the EMA zone at entry
   double zoneHigh = MathMax(emaFast, emaSlow);
   double zoneLow  = MathMin(emaFast, emaSlow);

   if(closePrice < zoneLow || closePrice > zoneHigh)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| CalculateStopLoss                                                  |
//| BUY:  SL = EMA50 minus buffer                                      |
//| SELL: SL = EMA50 plus buffer                                       |
//+------------------------------------------------------------------+
double CalculateStopLoss(const int tradeType, const double emaSlow)
{
   double bufferPrice = InpEMABufferPoints * _Point;

   if(tradeType == ORDER_TYPE_BUY)
      return NormalizeDouble(emaSlow - bufferPrice, _Digits);

   if(tradeType == ORDER_TYPE_SELL)
      return NormalizeDouble(emaSlow + bufferPrice, _Digits);

   return 0.0;
}

//+------------------------------------------------------------------+
//| CalculateTakeProfit                                                 |
//| TP = entry + (risk distance × RR ratio) for BUY                    |
//| TP = entry - (risk distance × RR ratio) for SELL                   |
//+------------------------------------------------------------------+
double CalculateTakeProfit(const int tradeType,
                           const double entryPrice,
                           const double stopLoss)
{
   double risk = MathAbs(entryPrice - stopLoss);
   double tpDistance = risk * InpRiskRewardRatio;

   if(tradeType == ORDER_TYPE_BUY)
      return NormalizeDouble(entryPrice + tpDistance, _Digits);

   if(tradeType == ORDER_TYPE_SELL)
      return NormalizeDouble(entryPrice - tpDistance, _Digits);

   return 0.0;
}

//+------------------------------------------------------------------+
//| RiskManagement                                                     |
//| Validates lot size and checks whether sufficient margin exists.    |
//| Returns true if the trade is allowed.                              |
//+------------------------------------------------------------------+
bool RiskManagement(const double lotSize, const int tradeType)
{
   // Enforce hard maximum lot size
   if(lotSize > MAX_LOT_SIZE)
   {
      Print("RISK: Lot size (", lotSize, ") exceeds maximum (", MAX_LOT_SIZE, "). Trade blocked.");
      return false;
   }

   // Verify trading is allowed on this symbol
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("RISK: Auto-trading is disabled in terminal settings. Trade blocked.");
      return false;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("RISK: Trading not allowed for this EA (check Expert Properties). Trade blocked.");
      return false;
   }

   // Check available margin
   double marginRequired = 0.0;

   if(!OrderCalcMargin((ENUM_ORDER_TYPE)tradeType, _Symbol, lotSize,
                        SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginRequired))
   {
      Print("RISK: OrderCalcMargin failed. Error: ", GetLastError(), ". Trade blocked.");
      return false;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginRequired > freeMargin)
   {
      Print("RISK: Insufficient margin. Required: ", marginRequired,
            " | Available: ", freeMargin, ". Trade blocked.");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| OpenBuyTrade                                                       |
//| Opens a BUY market order with calculated SL and TP.               |
//+------------------------------------------------------------------+
void OpenBuyTrade(const double emaFast, const double emaSlow)
{
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl       = CalculateStopLoss(ORDER_TYPE_BUY, emaSlow);
   double tp       = CalculateTakeProfit(ORDER_TYPE_BUY, askPrice, sl);

   // Validate price is within EMA zone (between EMA20 and EMA50)
   double zoneHigh = MathMax(emaFast, emaSlow);
   double zoneLow  = MathMin(emaFast, emaSlow);
   if(askPrice < zoneLow || askPrice > zoneHigh)
   {
      Print("WARNING: BUY entry price (", askPrice, ") outside EMA zone [", zoneLow, "–", zoneHigh, "]. Trade skipped.");
      return;
   }

   // Validate SL is below entry
   if(sl >= askPrice)
   {
      Print("ERROR: Invalid BUY SL (", sl, ") >= Ask (", askPrice, "). Trade skipped.");
      return;
   }

   if(!RiskManagement(InpLotSize, ORDER_TYPE_BUY))
      return;

   Print("Opening BUY | Ask: ", askPrice, " | SL: ", sl, " | TP: ", tp,
         " | Lot: ", InpLotSize);

   if(!g_trade.Buy(InpLotSize, _Symbol, askPrice, sl, tp, "EMA Pullback BUY"))
   {
      Print("ERROR: Buy order failed. RetCode: ", g_trade.ResultRetcode(),
            " | ", g_trade.ResultRetcodeDescription());
   }
   else
   {
      Print("BUY order placed successfully. Ticket: ", g_trade.ResultOrder());
   }
}

//+------------------------------------------------------------------+
//| OpenSellTrade                                                      |
//| Opens a SELL market order with calculated SL and TP.              |
//+------------------------------------------------------------------+
void OpenSellTrade(const double emaFast, const double emaSlow)
{
   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl       = CalculateStopLoss(ORDER_TYPE_SELL, emaSlow);
   double tp       = CalculateTakeProfit(ORDER_TYPE_SELL, bidPrice, sl);

   // Validate price is within EMA zone (between EMA20 and EMA50)
   double zoneHigh = MathMax(emaFast, emaSlow);
   double zoneLow  = MathMin(emaFast, emaSlow);
   if(bidPrice < zoneLow || bidPrice > zoneHigh)
   {
      Print("WARNING: SELL entry price (", bidPrice, ") outside EMA zone [", zoneLow, "–", zoneHigh, "]. Trade skipped.");
      return;
   }

   // Validate SL is above entry
   if(sl <= bidPrice)
   {
      Print("ERROR: Invalid SELL SL (", sl, ") <= Bid (", bidPrice, "). Trade skipped.");
      return;
   }

   if(!RiskManagement(InpLotSize, ORDER_TYPE_SELL))
      return;

   Print("Opening SELL | Bid: ", bidPrice, " | SL: ", sl, " | TP: ", tp,
         " | Lot: ", InpLotSize);

   if(!g_trade.Sell(InpLotSize, _Symbol, bidPrice, sl, tp, "EMA Pullback SELL"))
   {
      Print("ERROR: Sell order failed. RetCode: ", g_trade.ResultRetcode(),
            " | ", g_trade.ResultRetcodeDescription());
   }
   else
   {
      Print("SELL order placed successfully. Ticket: ", g_trade.ResultOrder());
   }
}

//+------------------------------------------------------------------+
//| ManageTrailingStop                                                 |
//| Implements a dynamic trailing stop that:                           |
//| - Activates once profit reaches 1R (risk distance)                 |
//| - Trails following EMA50 on M1                                     |
//| - Never reduces existing profit protection                         |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double emaSlowCurrent = 0.0, emaSlowPrev = 0.0;

   if(!GetEMAValues(g_emaSlowHandleM1, emaSlowCurrent, emaSlowPrev))
      return;

   double bufferPrice = InpEMABufferPoints * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)         continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)InpMagicNumber) continue;

      double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL    = PositionGetDouble(POSITION_SL);
      double currentTP    = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      // Calculate 1R (the initial risk distance)
      double riskDistance = MathAbs(openPrice - currentSL);
      if(riskDistance <= 0) continue;

      if(posType == POSITION_TYPE_BUY)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitDistance = currentBid - openPrice;

         // Only trail once profit >= 1R
         if(profitDistance < riskDistance) continue;

         // New SL trails EMA50 with a buffer below it
         double newSL = NormalizeDouble(emaSlowCurrent - bufferPrice, _Digits);

         // Only move SL up – never down (protect profits)
         if(newSL > currentSL + _Point)
         {
            if(!g_trade.PositionModify(ticket, newSL, currentTP))
            {
               Print("ERROR: Failed to modify BUY trailing stop. RetCode: ",
                     g_trade.ResultRetcode(), " | ", g_trade.ResultRetcodeDescription());
            }
            else
            {
               Print("Trailing stop updated for BUY ticket ", ticket,
                     ". New SL: ", newSL);
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitDistance = openPrice - currentAsk;

         // Only trail once profit >= 1R
         if(profitDistance < riskDistance) continue;

         // New SL trails EMA50 with a buffer above it
         double newSL = NormalizeDouble(emaSlowCurrent + bufferPrice, _Digits);

         // Only move SL down – never up (protect profits)
         if(newSL < currentSL - _Point)
         {
            if(!g_trade.PositionModify(ticket, newSL, currentTP))
            {
               Print("ERROR: Failed to modify SELL trailing stop. RetCode: ",
                     g_trade.ResultRetcode(), " | ", g_trade.ResultRetcodeDescription());
            }
            else
            {
               Print("Trailing stop updated for SELL ticket ", ticket,
                     ". New SL: ", newSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| PositionExists                                                     |
//| Returns true if there is already an open position on this symbol   |
//| with the EA's magic number.                                        |
//+------------------------------------------------------------------+
bool PositionExists()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL)  == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == (long)InpMagicNumber)
         return true;
   }
   return false;
}
//+------------------------------------------------------------------+
