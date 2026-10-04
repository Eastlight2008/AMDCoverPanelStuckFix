@echo off
rem ============================================================================
rem  回滚: 把 AMD 面板 "保活" 两项恢复成 AMD 出厂默认值
rem ----------------------------------------------------------------------------
rem  默认值来源: C:\Program Files\AMD\CNext\CNext\cn.reg
rem      "UnloadDelay"        = dword:0000012c  -> 300
rem      "MemorySizeTreshold" = dword:000000c8  -> 200
rem ============================================================================
setlocal EnableExtensions
title AMD Panel Keep-Alive - Rollback
set "KEY=HKLM\SOFTWARE\AMD\CN"

if /i "%~1"=="elev" goto :run
whoami /groups | findstr /c:"S-1-16-12288" >nul 2>&1
if errorlevel 1 (
    echo [i] Not elevated. Requesting UAC elevation...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList 'elev'"
    exit /b
)

:run
echo ============================================================================
echo   Rollback AMD panel keep-alive tweak  -  restore factory defaults
echo   Key: %KEY%
echo ============================================================================
echo.
echo ---- BEFORE ----
reg query "%KEY%" /v UnloadDelay
reg query "%KEY%" /v MemorySizeTreshold
echo.
echo ---- WRITE ----
echo [1/2] UnloadDelay        -^> 300   factory default
reg add "%KEY%" /v UnloadDelay /t REG_DWORD /d 300 /f
echo [2/2] MemorySizeTreshold -^> 200   factory default
reg add "%KEY%" /v MemorySizeTreshold /t REG_DWORD /d 200 /f
echo.
echo ---- AFTER   expect 0x12c and 0xc8 ----
reg query "%KEY%" /v UnloadDelay
reg query "%KEY%" /v MemorySizeTreshold
echo.
echo [OK] Restored. Panel goes back to unloading itself after 5 idle minutes.
echo.
pause
endlocal
