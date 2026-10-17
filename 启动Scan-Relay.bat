@echo off
chcp 65001 >nul 2>nul
title Scan-Relay 服务（关闭本窗口即停止）
cd /d "%~dp0server"
where python >nul 2>nul
if errorlevel 1 (
  echo [错误] 未找到 python，请先安装 Python 3
  pause
  exit /b 1
)
python relay.py
pause
