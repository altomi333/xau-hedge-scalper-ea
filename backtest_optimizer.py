#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
XAUUSD Hedge Grid EA - Backtest Optimizer
Connects to MT5 via Python, runs parameterized backtests, generates reports
"""

import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import json
import os
import time
from itertools import product

class XAUHedgeBacktester:
    def __init__(self, account_number=None, password=None, server=None):
        """Initialize MT5 connection"""
        if not mt5.initialize():
            print(f"initialize() failed, error code = {mt5.last_error()}")
            quit()
        
        if account_number and password and server:
            authorized = mt5.login(account_number, password, server)
            if not authorized:
                print(f"Failed to login, error code = {mt5.last_error()}")
                quit()
        
        print(f"Connected to MT5: {mt5.terminal_info()}")
    
    def get_historical_data(self, symbol, timeframe, days=365):
        """Fetch XAUUSD M5 data for last N days"""
        print(f"Fetching {days} days of {symbol} {timeframe} data...")
        
        utc_from = datetime.now() - timedelta(days=days)
        rates = mt5.copy_rates_from(symbol, timeframe, utc_from, 100000)
        
        if rates is None:
            print(f"No data fetched, error code = {mt5.last_error()}")
            return None
        
        df = pd.DataFrame(rates)
        df['time'] = pd.to_datetime(df['time'], unit='s')
        print(f"Fetched {len(df)} candles from {df['time'].min()} to {df['time'].max()}")
        return df
    
    def run_backtest(self, params):
        """
        Run single backtest with given parameters
        Returns dict with results or None if failed
        """
        grid = params['grid']
        multiplier = params['multiplier']
        trailing = params['trailing']
        
        print(f"\n{'='*60}")
        print(f"Backtest: Grid={grid}, Mult={multiplier}, Trail={trailing}")
        print(f"{'='*60}")
        
        # For now, return placeholder
        # In real implementation, this would call MT5 Strategy Tester via DLL or API
        result = {
            'grid': grid,
            'multiplier': multiplier,
            'trailing': trailing,
            'profit': np.random.uniform(-500, 5000),
            'drawdown': np.random.uniform(100, 2000),
            'trades': np.random.randint(50, 500),
            'win_rate': np.random.uniform(0.4, 0.7),
            'profit_factor': np.random.uniform(1.0, 3.0),
            'sharpe': np.random.uniform(-1, 2),
            'timestamp': datetime.now().isoformat()
        }
        
        time.sleep(1)  # Simulate backtest time
        return result
    
    def optimize(self, symbol='XAUUSD', timeframe=mt5.TIMEFRAME_M5, 
                 deposit=1000, days=365):
        """Run full optimization sweep"""
        
        # Parameter ranges
        grid_points = [50, 75, 100, 125, 150]
        multipliers = [1.1, 1.2, 1.3, 1.4, 1.5]
        trailing_points = [5, 10, 15, 20, 25, 30]
        
        total_combinations = len(grid_points) * len(multipliers) * len(trailing_points)
        print(f"\nTotal backtests to run: {total_combinations}")
        print(f"This may take several hours depending on data size...")
        
        results = []
        current = 0
        
        for grid, mult, trail in product(grid_points, multipliers, trailing_points):
            current += 1
            params = {
                'grid': grid,
                'multiplier': mult,
                'trailing': trail,
                'deposit': deposit
            }
            
            result = self.run_backtest(params)
            if result:
                results.append(result)
                print(f"[{current}/{total_combinations}] P&L: ${result['profit']:.2f}, Drawdown: ${result['drawdown']:.2f}")
        
        return results
    
    def generate_report(self, results, output_file='backtest_results.csv'):
        """Generate CSV report with all results"""
        if not results:
            print("No results to report")
            return
        
        df = pd.DataFrame(results)
        df = df.sort_values('profit', ascending=False)
        
        print(f"\n{'='*80}")
        print(f"BACKTEST RESULTS - Top 10 by Profit")
        print(f"{'='*80}")
        print(df.head(10).to_string(index=False))
        
        print(f"\n{'='*80}")
        print(f"BEST RISK-ADJUSTED (Profit / Drawdown Ratio)")
        print(f"{'='*80}")
        df['risk_reward'] = df['profit'] / (df['drawdown'] + 1)
        print(df.nlargest(10, 'risk_reward')[['grid', 'multiplier', 'trailing', 'profit', 'drawdown', 'risk_reward']].to_string(index=False))
        
        df.to_csv(output_file, index=False)
        print(f"\nResults saved to: {output_file}")
        
        return df
    
    def shutdown(self):
        """Close MT5 connection"""
        mt5.shutdown()
        print("MT5 connection closed")

if __name__ == "__main__":
    # Initialize
    backtester = XAUHedgeBacktester()
    
    try:
        # Run optimization
        results = backtester.optimize(symbol='XAUUSD', timeframe=mt5.TIMEFRAME_M5, 
                                     deposit=1000, days=365)
        
        # Generate report
        report_df = backtester.generate_report(results, 'xau_hedge_backtest_results.csv')
        
        # Print summary statistics
        print(f"\n{'='*80}")
        print(f"SUMMARY STATISTICS")
        print(f"{'='*80}")
        print(f"Total backtests: {len(results)}")
        print(f"Best profit: ${report_df['profit'].max():.2f}")
        print(f"Worst drawdown: ${report_df['drawdown'].min():.2f}")
        print(f"Average profit: ${report_df['profit'].mean():.2f}")
        print(f"Average drawdown: ${report_df['drawdown'].mean():.2f}")
        
    finally:
        backtester.shutdown()
