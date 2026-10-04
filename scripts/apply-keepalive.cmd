@echo off
rem ============================================================================
rem  AMD Radeon Software 面板 "保活" 设置  --  只改这两个值
rem ----------------------------------------------------------------------------
rem  目的: 面板默认空闲 300 秒就把自己卸载, 下次"呼出"变成冷启动,
rem        于是出现"只有顶栏、没有设置内容"。把空闲卸载时间拉长, 并抬高
rem        内存触发的卸载门槛, 让面板长期保持热的, 呼出即可用。
rem
rem  目标键 : HKLM\SOFTWARE\AMD\CN
rem  改前   : UnloadDelay=300 (0x12c)   MemorySizeTreshold=200 (0xc8)
rem           以上是 AMD 出厂默认值, 来自 cn.reg, 不是被改过的值
rem  改后   : UnloadDelay=86400 (0x15180, 24 小时)   MemorySizeTreshold=1024 (0x400)
rem  生效   : 面板下次启动时读取, 无需重启电脑
rem  注意   : 更新/重装显卡驱动会重新导入 cn.reg, 本改动会被重置
rem  回滚   : 以管理员身份运行 rollback-keepalive.cmd
rem ============================================================================
setlocal EnableExtensions
title AMD Panel Keep-Alive - Apply
set "KEY=HKLM\SOFTWARE\AMD\CN"
set "NEW_UNLOAD=86400"
set "NEW_MEM=1024"
set "OLD_UNLOAD=300"
set "OLD_MEM=200"

rem ---- 提权: 用 SID 判断管理员令牌(与系统语言无关); 带 elev 标记防止重复弹窗 ----
if /i "%~1"=="elev" goto :run
whoami /groups | findstr /c:"S-1-16-12288" >nul 2>&1
if errorlevel 1 (
    echo [i] Not elevated. Requesting UAC elevation...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList 'elev'"
    exit /b
)

:run
echo ============================================================================
echo   AMD Radeon Software panel - keep-alive registry tweak
echo   Key: %KEY%
echo ============================================================================
echo.
echo ---- BEFORE ----
reg query "%KEY%" /v UnloadDelay
reg query "%KEY%" /v MemorySizeTreshold
echo.
echo ---- WRITE ----
echo [1/2] UnloadDelay        : %OLD_UNLOAD% -^> %NEW_UNLOAD%   seconds
reg add "%KEY%" /v UnloadDelay /t REG_DWORD /d %NEW_UNLOAD% /f
if errorlevel 1 goto :fail
echo [2/2] MemorySizeTreshold : %OLD_MEM% -^> %NEW_MEM%   MB
reg add "%KEY%" /v MemorySizeTreshold /t REG_DWORD /d %NEW_MEM% /f
if errorlevel 1 goto :fail
echo.
echo ---- AFTER   expect 0x15180 and 0x400 ----
reg query "%KEY%" /v UnloadDelay
reg query "%KEY%" /v MemorySizeTreshold
echo.
echo [OK] Done. Panel is not running now, so new values apply at next launch
echo      with Alt+R. No reboot needed.
echo      Undo: run rollback-keepalive.cmd as administrator.
goto :done

:fail
echo.
echo [X] Write FAILED, errorlevel %errorlevel%. Nothing was changed.
goto :done

:done
echo.
pause
endlocal
