//+------------------------------------------------------------------+
//|  XAUUSD_Hedge_Grid_Pro.mq5                                       |
//|  Aggressive hedge grid EA for XAUUSD M5                          |
//|  Designed for hedge account, unlimited side growth during testing |
//|                                                                  |
//|  Strategy concept:                                                |
//|    - Open symmetrical buy/sell hedge at init                       |
//|    - Add new orders on each side when price moves by grid distance|
//|    - Scale lot with multiplier (1.3) per side                     |
//|    - Trailing stop based on points                                |
//|    - Close all on global profit if enabled                        |
//|                                                                  |
//|  IMPORTANT: This is a research EA for backtests and optimization.  |
//|  Do not deploy to live capital without thorough validation.       |
//+------------------------------------------------------------------+
#property copyright "Ruflo / XAU Test EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input long    InpMagic              = 4201;         // Magic number
input double  InpBaseLot            = 0.01;         // Base lot
input double  InpLotMultiplier      = 1.3;          // Lot multiplier per side order count
input int     InpGridPoints         = 100;          // Grid distance in points
input int     InpMaxPerSide         = 0;            // 0 = unlimited
input int     InpTrailingPoints     = 20;           // Trailing stop distance in points
input int     InpDeviation          = 20;           // Slippage / deviation in points
input int     InpMaxSpreadPoints    = 0;            // 0 = disabled, max spread filter
input double  InpProfitTarget       = 0.0;          // 0 = disabled; close all when total profit >= target
input double  InpCloseAllThreshold  = 0.0;          // 0 = disabled; close all when global P&L >= value
input double  InpHedgeBalanceRatio  = 1.50;         // Rebalance if buy/sell volume ratio exceeds this
input int     InpMinPositionsToRebalance = 2;         // Rebalance only when both sides hold at least this many
input bool    InpCloseBySide        = true;         // Close full side when it reaches side profit
input double  InpSideProfitTarget   = 0.0;          // 0 = disabled; close side if its P&L >= value
input bool    InpUseInitialPair     = true;         // Open first buy + first sell at startup
input bool    InpUseTrailing        = true;         // Use trailing stops
input bool    InpEnableRebalance    = true;         // Use hedge rebalance
input bool    InpEnableCloseAll     = true;         // Close all on global profit if target enabled

CTrade g_trade;
string g_symbol;

struct PositionStats
  {
   int buyCount;
   int sellCount;
   double buyVolume;
   double sellVolume;
   double buyProfit;
   double sellProfit;
   double buyWorstOpen;
   double sellWorstOpen;
  };

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   if(minLot <= 0) minLot = 0.01;
   if(maxLot <= 0) maxLot = 100.0;

   lot = MathFloor(lot / step + 0.5) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
  }

bool IsHedgeAccount(void)
  {
   return (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
  }

bool CanOpenOrder(double lot, bool isBuy)
  {
   if(InpMaxSpreadPoints > 0)
     {
      int spread = (int)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
         return false;
     }

   double price = isBuy ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double reqMargin = 0.0;
   if(!OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, g_symbol, lot, price, reqMargin))
      return false;

   if(reqMargin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      return false;

   return true;
  }

double SideDistanceInPoints(bool isBuy)
  {
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return InpGridPoints * point;
  }

int GetOpenOrdersByMagicAndSymbol(void)
  {
   int count = 0;
   for(int i = OrdersTotal()-1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != g_symbol)
         continue;
      if(OrderMagicNumber() != InpMagic)
         continue;
      count++;
     }
   return count;
  }

void CloseAllPositions(void)
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      g_trade.PositionClose(ticket);
     }
  }

void CloseSide(int type)
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;
      g_trade.PositionClose(ticket);
     }
  }

void ScanPositions(PositionStats &stats)
  {
   stats.buyCount = 0;
   stats.sellCount = 0;
   stats.buyVolume = 0.0;
   stats.sellVolume = 0.0;
   stats.buyProfit = 0.0;
   stats.sellProfit = 0.0;
   stats.buyWorstOpen = 0.0;
   stats.sellWorstOpen = 0.0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      int type = (int)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
        {
         stats.buyCount++;
         stats.buyVolume += vol;
         stats.buyProfit += profit;
         if(stats.buyWorstOpen == 0.0 || openPrice < stats.buyWorstOpen)
            stats.buyWorstOpen = openPrice;
        }
      else if(type == POSITION_TYPE_SELL)
        {
         stats.sellCount++;
         stats.sellVolume += vol;
         stats.sellProfit += profit;
         if(stats.sellWorstOpen == 0.0 || openPrice > stats.sellWorstOpen)
            stats.sellWorstOpen = openPrice;
        }
     }
  }

bool NeedRebalance(PositionStats &stats)
  {
   if(!InpEnableRebalance)
      return false;
   if(stats.buyCount < InpMinPositionsToRebalance || stats.sellCount < InpMinPositionsToRebalance)
      return false;

   double buyVol = stats.buyVolume;
   double sellVol = stats.sellVolume;
   if(buyVol <= 0 || sellVol <= 0)
      return false;

   double ratio = MathMax(buyVol, sellVol) / MathMin(buyVol, sellVol);
   return (ratio >= InpHedgeBalanceRatio);
  }

void RebalanceSide(void)
  {
   PositionStats stats;
   ScanPositions(stats);
   if(!NeedRebalance(stats))
      return;

   double buyVol = stats.buyVolume;
   double sellVol = stats.sellVolume;
   double target = MathMax(buyVol, sellVol) - MathMin(buyVol, sellVol);
   target *= 0.50;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double vol = NormalizeLot(target);

   if(vol <= 0.0)
      return;

   if(buyVol > sellVol && CanOpenOrder(vol, false))
      g_trade.Sell(vol, g_symbol, bid, 0.0, 0.0, "HEDGE_REBALANCE");
   else if(sellVol > buyVol && CanOpenOrder(vol, true))
      g_trade.Buy(vol, g_symbol, ask, 0.0, 0.0, "HEDGE_REBALANCE");
  }

void TrailPositions(void)
  {
   if(!InpUseTrailing)
      return;

   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double trailDistance = InpTrailingPoints * point;
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
        {
         double actualProfit = bid - openPrice;
         if(actualProfit >= trailDistance)
           {
            double newSL = bid - trailDistance;
            if(sl == 0.0 || newSL > sl)
               g_trade.PositionModify(ticket, newSL, tp);
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double actualProfit = openPrice - ask;
         if(actualProfit >= trailDistance)
           {
            double newSL = ask + trailDistance;
            if(sl == 0.0 || newSL < sl)
               g_trade.PositionModify(ticket, newSL, tp);
           }
        }
     }
  }

bool TryOpenInitialPair(void)
  {
   if(!InpUseInitialPair)
      return false;

   PositionStats stats;
   ScanPositions(stats);
   if(stats.buyCount > 0 || stats.sellCount > 0)
      return false;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double baseLot = NormalizeLot(InpBaseLot);
   if(!CanOpenOrder(baseLot, true))
      return false;
   if(!CanOpenOrder(baseLot, false))
      return false;

   g_trade.Buy(baseLot, g_symbol, ask, 0.0, 0.0, "HEDGE_INIT_BUY");
   g_trade.Sell(baseLot, g_symbol, bid, 0.0, 0.0, "HEDGE_INIT_SELL");
   return true;
  }

bool TryOpenSide(bool isBuy)
  {
   PositionStats stats;
   ScanPositions(stats);

   int sideCount = isBuy ? stats.buyCount : stats.sellCount;
   if(InpMaxPerSide > 0 && sideCount >= InpMaxPerSide)
      return false;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double gridDistance = SideDistanceInPoints(isBuy);
   double nextLot = NormalizeLot(InpBaseLot * MathPow(InpLotMultiplier, sideCount));

   if(isBuy)
     {
      if(sideCount == 0)
        {
         if(CanOpenOrder(nextLot, true))
            {
             g_trade.Buy(nextLot, g_symbol, ask, 0.0, 0.0, "HEDGE_BUY");
             return true;
            }
         return false;
        }

      double worstOpen = stats.buyWorstOpen;
      if(worstOpen > 0.0 && ask <= worstOpen - gridDistance)
        {
         if(CanOpenOrder(nextLot, true))
            {
             g_trade.Buy(nextLot, g_symbol, ask, 0.0, 0.0, "HEDGE_BUY");
             return true;
            }
        }
     }
   else
     {
      if(sideCount == 0)
        {
         if(CanOpenOrder(nextLot, false))
            {
             g_trade.Sell(nextLot, g_symbol, bid, 0.0, 0.0, "HEDGE_SELL");
             return true;
            }
         return false;
        }

      double worstOpen = stats.sellWorstOpen;
      if(worstOpen > 0.0 && bid >= worstOpen + gridDistance)
        {
         if(CanOpenOrder(nextLot, false))
            {
             g_trade.Sell(nextLot, g_symbol, bid, 0.0, 0.0, "HEDGE_SELL");
             return true;
            }
        }
     }

   return false;
  }

void CheckCloseRules(void)
  {
   PositionStats stats;
   ScanPositions(stats);

   double totalProfit = stats.buyProfit + stats.sellProfit;

   if(InpEnableCloseAll && InpCloseAllThreshold > 0.0 && totalProfit >= InpCloseAllThreshold)
     {
      CloseAllPositions();
      return;
     }

   if(InpProfitTarget > 0.0 && totalProfit >= InpProfitTarget)
     {
      CloseAllPositions();
      return;
     }

   if(InpCloseBySide && InpSideProfitTarget > 0.0)
     {
      if(stats.buyCount > 0 && stats.buyProfit >= InpSideProfitTarget)
         CloseSide(POSITION_TYPE_BUY);
      if(stats.sellCount > 0 && stats.sellProfit >= InpSideProfitTarget)
         CloseSide(POSITION_TYPE_SELL);
     }
  }

int OnInit()
  {
   g_symbol = _Symbol;
   if(!IsHedgeAccount())
     {
      Alert("This EA requires a hedge account. Exiting.");
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviation);
   g_trade.SetTypeFillingBySymbol(g_symbol);

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
  }

void OnTick()
  {
   if(!IsTradeAllowed())
      return;

   PositionStats stats;
   ScanPositions(stats);

   if(stats.buyCount == 0 && stats.sellCount == 0)
      TryOpenInitialPair();

   CheckCloseRules();
   TrailPositions();

   PositionStats refreshed;
   ScanPositions(refreshed);

   if(!NeedRebalance(refreshed))
     {
      // Open more orders when price moves away from the worst open price
      if(refreshed.buyCount > 0 || refreshed.sellCount > 0)
        {
         if(refreshed.buyCount == 0 && refreshed.sellCount >= 1)
           TryOpenSide(true);
         if(refreshed.sellCount == 0 && refreshed.buyCount >= 1)
           TryOpenSide(false);

         if(refreshed.buyCount > 0)
           TryOpenSide(true);
         if(refreshed.sellCount > 0)
           TryOpenSide(false);
        }
     }

   RebalanceSide();

   Comment("XAU Hedge Grid\nBUY=", stats.buyCount,
           " SELL=", stats.sellCount,
           "\nBUYV=", DoubleToString(stats.buyVolume, 2),
           " SELLV=", DoubleToString(stats.sellVolume, 2),
           "\nP&L=", DoubleToString(stats.buyProfit + stats.sellProfit, 2));
  }
//+------------------------------------------------------------------+
//| End of file                                                       |
//+------------------------------------------------------------------+
