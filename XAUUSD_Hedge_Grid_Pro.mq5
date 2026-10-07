//+------------------------------------------------------------------+
//|  XAUUSD_Hedge_Grid_Pro.mq5                                       |
//|  Hedge grid EA for XAUUSD M5 - MT5 Corrected Version             |
//|  Base version corrected for proper MT5 position handling          |
//+------------------------------------------------------------------+
#property copyright "Ruflo / XAU Grid EA"
#property version   "1.03"
#property strict

#include <Trade/Trade.mqh>

input long    InpMagic              = 4201;
input double  InpBaseLot            = 0.01;
input double  InpLotMultiplier      = 1.3;
input int     InpGridPoints         = 100;
input int     InpTrailingPoints     = 20;
input int     InpDeviation          = 20;
input int     InpMaxPerSide         = 0;        // 0 = unlimited
input int     InpMaxSpreadPoints    = 0;        // 0 = disabled
input bool    InpUseInitialPair     = true;
input bool    InpUseTrailing        = true;

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

double NormalizeLot(double lot)
{
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0.0) step = 0.01;
   if(minLot <= 0.0) minLot = 0.01;
   if(maxLot <= 0.0) maxLot = 100.0;

   lot = MathFloor(lot / step + 0.5) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

bool IsHedgeAccount()
{
   return (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

void SelectPositionByTicket(ulong ticket)
{
   if(ticket == 0) return;
   PositionSelectByTicket(ticket);
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

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      SelectPositionByTicket(ticket);

      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(type == (int)POSITION_TYPE_BUY)
      {
         stats.buyCount++;
         stats.buyVolume += vol;
         stats.buyProfit += profit;
         if(stats.buyWorstOpen == 0.0 || openPrice < stats.buyWorstOpen)
            stats.buyWorstOpen = openPrice;
      }
      else if(type == (int)POSITION_TYPE_SELL)
      {
         stats.sellCount++;
         stats.sellVolume += vol;
         stats.sellProfit += profit;
         if(stats.sellWorstOpen == 0.0 || openPrice > stats.sellWorstOpen)
            stats.sellWorstOpen = openPrice;
      }
   }
}

bool OpenInitialPair()
{
   PositionStats stats;
   ScanPositions(stats);

   if(stats.buyCount > 0 || stats.sellCount > 0)
      return false;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double baseLot = NormalizeLot(InpBaseLot);

   if(!CanOpenOrder(baseLot, true)) return false;
   if(!CanOpenOrder(baseLot, false)) return false;

   g_trade.Buy(baseLot, g_symbol, ask, 0.0, 0.0, "INIT_BUY");
   g_trade.Sell(baseLot, g_symbol, bid, 0.0, 0.0, "INIT_SELL");

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
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double gridDistance = InpGridPoints * point;

   double nextLot = NormalizeLot(InpBaseLot * MathPow(InpLotMultiplier, sideCount));

   if(isBuy)
   {
      if(sideCount == 0)
      {
         if(CanOpenOrder(nextLot, true))
         {
            g_trade.Buy(nextLot, g_symbol, ask, 0.0, 0.0, "BUY_GRID");
            return true;
         }
         return false;
      }

      if(stats.buyWorstOpen > 0.0 && ask <= stats.buyWorstOpen - gridDistance)
      {
         if(CanOpenOrder(nextLot, true))
         {
            g_trade.Buy(nextLot, g_symbol, ask, 0.0, 0.0, "BUY_GRID");
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
            g_trade.Sell(nextLot, g_symbol, bid, 0.0, 0.0, "SELL_GRID");
            return true;
         }
         return false;
      }

      if(stats.sellWorstOpen > 0.0 && bid >= stats.sellWorstOpen + gridDistance)
      {
         if(CanOpenOrder(nextLot, false))
         {
            g_trade.Sell(nextLot, g_symbol, bid, 0.0, 0.0, "SELL_GRID");
            return true;
         }
      }
   }

   return false;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      SelectPositionByTicket(ticket);

      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      g_trade.PositionClose(ticket);
   }
}

void TrailPositions()
{
   if(!InpUseTrailing) return;

   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double trailDistance = InpTrailingPoints * point;
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      SelectPositionByTicket(ticket);

      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      if(type == (int)POSITION_TYPE_BUY)
      {
         double profit = bid - open;
         if(profit >= trailDistance)
         {
            double newSL = bid - trailDistance;
            if(sl == 0.0 || newSL > sl)
               g_trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(type == (int)POSITION_TYPE_SELL)
      {
         double profit = open - ask;
         if(profit >= trailDistance)
         {
            double newSL = ask + trailDistance;
            if(sl == 0.0 || newSL < sl)
               g_trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

int OnInit()
{
   g_symbol = _Symbol;

   if(!IsHedgeAccount())
   {
      Alert("This EA requires a hedge account.");
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
   PositionStats stats;
   ScanPositions(stats);

   if(stats.buyCount == 0 && stats.sellCount == 0 && InpUseInitialPair)
   {
      OpenInitialPair();
      return;
   }

   if(stats.buyCount > 0)
      TryOpenSide(true);

   if(stats.sellCount > 0)
      TryOpenSide(false);

   TrailPositions();

   Comment("BUY=", stats.buyCount, " SELL=", stats.sellCount,
           " BUYVOL=", DoubleToString(stats.buyVolume, 2),
           " SELLVOL=", DoubleToString(stats.sellVolume, 2),
           " P&L=", DoubleToString(stats.buyProfit + stats.sellProfit, 2));
}
//+------------------------------------------------------------------+
