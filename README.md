# AMD Software 面板「只剩顶栏、没有设置内容」——成因分析与缓解方案

> 针对 Adrenalin 26.x 的 Qt6/QML 面板（内部代号 RSX / CNext）
> 状态：**成因分析已完成（二进制级取证）；缓解方案属假设驱动，注册表层面已验证，行为层面需自测**

---

## English TL;DR

On AMD Adrenalin 26.x the settings panel (`RadeonSoftware.exe`) is a **Qt 6.9 QML application**, not a classic Win32 dialog. Its window is built in **two stages**: the shell (custom title bar / navigation) is created and shown first, while page views are created asynchronously through *hidden preload windows* plus a `ConnectModel` step. The binary contains roughly a dozen dedicated error branches for that preload path — `Can't preload %1. View creation failed.`, `... ConnectModel failed.`, `... Bad state.`, `... NO_PREREQUISITES`, `Component is not ready` — and in every one of them it **keeps the shell visible instead of crashing**. That is exactly why users occasionally see a title bar with an empty body and find no crash report anywhere.

Aggravating factor: AMD's own defaults (`HKLM\SOFTWARE\AMD\CN`: `UnloadDelay=300`, `MemorySizeTreshold=200`, `InitDelay=60`) make the panel **unload itself after ~5 idle minutes**, so most invocations are cold starts that have to rebuild the shell, re-load QML components and reconnect data models.

Mitigation discussed here: raise `UnloadDelay` / `MemorySizeTreshold` so the panel stays warm; recover a stuck panel with `cncmd.exe show | resume | restartandshow`. **This is not an official AMD fix** — it is a reverse-engineered analysis with a self-testable workaround.

---

## 1. 症状

呼出面板（默认热键 `Alt+R`）时，窗口出现了，但**只有顶部标题栏/导航条，中间的设置内容整片空白**。

关键特征：

- **不崩溃、不报错**：Windows 事件日志里没有 `Application Error` / `Application Hang`，WER 里没有 `RadeonSoftware.exe` 的记录。
- **偶发**：不是每次都这样，同一台机器上有时正常。
- **有两种形态**：
  - 空一会儿自己补齐（说明内容在异步加载）；
  - 一直空着不变，必须重启面板进程（说明预加载分支失败了）。

这两种形态的处理方式完全不同，见 [§7.2](#72-卡住时的恢复阶梯)。

---

## 2. 复现环境（本病例）

| 项 | 值 |
|---|---|
| CPU | AMD Ryzen 9 7950X |
| 主板 / BIOS | ASUS TUF GAMING B650M-PLUS / 3881 |
| 独显 | AMD Radeon RX 7900 XT（Navi 31，`744C`），驱动 `32.0.31041.1004` |
| 核显 | AMD Radeon Graphics（Raphael，`164E`），驱动 `32.0.21045.5002` |
| 第三块适配器 | 第三方虚拟显示适配器（GameViewer `15.6.5.199`） |
| 系统 | Windows 11 26H2，Build `26300.9550` |
| AMD Software | `CNVersion 26.10.41.01`（对外版本号 26.8.1，Adrenalin），包日期 2026-08-11 |
| 面板主程序 | `RadeonSoftware.exe` 文件版本 `10.01.02.2099`，29,067,528 字节 |
| UI 框架 | **Qt 6.9.0** + Qt Quick(QML) + QtWebEngine |

> 注：注册表 `ProductName` 显示为 "Windows 10 Pro for Workstations" 而 `CurrentBuild=26300`，这是 Win11 上常见的注册表遗留字段，不影响结论。

---

## 3. 结论速览

```
Alt+R / 托盘 / 计划任务
        │
        ▼
   cncmd.exe  ──(startwithdelay / restart / restartandshow)──►  RadeonSoftware.exe
   （启动器 + 看门狗）                                              │
                                                                    ├─ ① 先建「外壳」= 顶栏/导航条  → 立即可见  ★你看到的
                                                                    ├─ ② 建「隐藏预加载窗口」(HiddenPreloadWindow)
                                                                    │    qrc:/Qml/Common/PreloadWindow.qml
                                                                    ├─ ③ 逐个预加载页面组件 (*_ui_component)
                                                                    │    失败分支：Bad state / Component is not ready /
                                                                    │             View creation failed / ...
                                                                    └─ ④ ConnectModel：把页面接上数据模型
                                                                         失败分支：ConnectModel failed

  ①②③④ 任何一步慢或失败 → 代码选择「保留外壳继续显示」→ 只有顶栏，且无崩溃记录
```

**一句话**：顶栏是"外壳先行"的产物；设置内容要靠隐藏预加载窗口 + QML 组件加载 + 数据模型连接异步补齐。而面板默认**空闲 5 分钟就自我卸载**，所以绝大多数"呼出"其实是一次冷启动——呼出时机一旦落进这个窗口期，就先只看到顶栏。

---

## 4. 面板的进程与 UI 架构

### 4.1 启动链

```
开机 → 用户登录
   └─ 计划任务  StartCN  (LogonTrigger, 组 S-1-5-32-545, LeastPrivilege)
         └─ "C:\Program Files\AMD\CNext\CNext\cncmd.exe" startwithdelay
               └─ (InitDelay 默认 60 秒) → RadeonSoftware.exe
```

`StartCN.xml` / `StartDVR.xml` 是随驱动一起安装的任务定义文件：

| 任务 | 触发 | 执行 |
|---|---|---|
| `StartCN` | 登录时 | `cncmd.exe startwithdelay` |
| `StartDVR` | 登录时 | `RSServCmd.exe` |

### 4.2 程序构成（决定了故障形态）

安装目录 `C:\Program Files\AMD\CNext\CNext\` 里能看到它不是传统 Win32 程序：

```
Qt6Core/Qml/Quick/QuickControls2/Widgets ...   ← Qt 6.9 全套
Qt6WebEngineCore.dll               199 MB     ← 内嵌 Chromium
QtWebEngineProcess.exe                        ← Chromium 渲染进程
resources.rcc / creator.rcc / workstation.rcc ← 打包的 QML 资源
RadeonSoftware.exe                  29 MB     ← 主程序（QML 源码以字符串形式内嵌其中）
cncmd.exe                                     ← 启动器 + 看门狗
AMDRSServ.exe / RSServCmd.exe                 ← 服务侧（数据/录制/叠加层）
```

主程序内可提取到的 QML 页面结构：

```
qrc:/Qml/RSX/Main.qml
qrc:/Qml/RSX/MainDesktopWindow.qml        ← 外壳窗口
qrc:/Qml/Common/PreloadWindow.qml         ← 隐藏预加载窗口
qrc:/Qml/RSX/Dashboard/*   (DashboardPanel, LastPlayed, RecentMedia, ...)
qrc:/Qml/RSX/Gaming/*      (GamePage, Graphics, GameList, ...)
qrc:/Qml/RSX/Performance/* (Metrics, Tuning, PerfMonitor, ...)
qrc:/Qml/RSX/Settings/*    (Performance, EDID, ...)
qrc:/Qml/Launcher/Launcher.qml
```

> QtWebEngine 的实际用途是**授权对话框**（"连接账号" 里的 `Loader` + `WebEngineView`），不是主页面。
> 且 AMD 强制它走软件渲染：`QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu`。

---

## 5. 「只有顶栏」的直接机理（二进制级证据）

以下字符串直接从 `RadeonSoftware.exe` 中提取，构成一条完整的"外壳预加载"状态机**及其全部失败分支**：

```
Preload Shell Start: %1        ...   Preload Shell End: %1
Failed to wait for all UI preload finish.
Not all runtimes preloaded for part %1.
Can't preload UI %1. NO_PREREQUISITES
Failed to init shell apps. Unknown %1
Failed to notify %1 preload finished.      /  Failed to notify %1 - not found.
Can't preload %1. Bad state.
Can't create component for %1 (%2). Component is not ready.
Can't preload %1. View creation failed.
Can't preload %1. ConnectModel failed.     ← 页面拿不到数据模型
Can't preload %1. Model creation failed.
Can't preload %1. Can't find shell's context. / VIEW / canvas.
Cant find hidden preload window.
Pause request was recieved to already paused process.
Resume request was recieved when not-paused.   ← 暂停/恢复状态机失步告警
RestoreToFactory is called for view switch. Will restart process, no UI shown after.
Failed to get private working set size.        ← 按内存占用决定卸载
```

同时可提取到 Qt 相关的类型与对象名，印证"隐藏预加载窗口"这一设计：

```
UI_Common::HiddenPreloadWindow
QQmlListProperty<UI_Common::HiddenPreloadWindow>
UI_Common::CNApplicationWindow      /  QQmlListProperty<UI_Common::CNApplicationWindow>
preloadWindowObjectName
hidden_preload_component
```

**三个要点：**

1. **外壳与内容分离**：`Preload Shell Start/End` + `launcherWindow` + `cnAppArea` 说明顶栏/外壳是独立创建的窗口对象，先出来；设置页是之后的 `View` + `ConnectModel`。
2. **失败即"留壳"**：上面每一条都是**独立的错误分支**，程序在此之后继续显示窗口、不退出、不打崩溃报告。所以症状表现为"顶栏在、内容缺"，而不是闪退。
3. **还有两条会主动离开的路径**：
   - `RestoreToFactory ... Will restart process, no UI shown after.` —— 某些视图切换会**重启整个进程且期间不显示 UI**；
   - 看门狗识别的退出码 `EXIT_FOR_GPU_LOST` / `EXIT_FOR_GPU_LOST_SILENT` / `EXIT_FOR_MEMORY_EXCEPTION` / `EXIT_FOR_OTHER_EXCEPTION` —— GPU 丢失或内存异常时进程会退出，由 `cncmd.exe` 的 `WatchRsx()` 决定 `attempt recovery` 还是 `will not recover`。

---

## 6. 生命周期：为什么"呼出"多半是冷启动

`C:\Program Files\AMD\CNext\CNext\cn.reg` 是随驱动一起下发的注册表默认值模板，其中：

```ini
[HKEY_LOCAL_MACHINE\SOFTWARE\AMD\CN]
"UnloadDelay"        =dword:0000012c   ; 300   —— 空闲多久卸载 UI（秒）
"MemorySizeTreshold" =dword:000000c8   ; 200   —— 内存维度触发卸载的门槛（MB）
"InitDelay"          =dword:0000003c   ; 60    —— 登录后延迟多久预热面板（秒）
"Benchmark"          = "false"
"CollectGIData"      =dword:00000000
```

对应代码里的行为字符串（同一段逻辑里能看到）：

```
Failed to get value for Preload Delay. Setting it to 300.
Failed to get value for Unload Delay. Setting it to -1.
Unload Delay value of %1 is invalid. Setting it to 1800.
Preload timer event is recieved.
Unload timer event is recieved.
Failed to get private working set size.
```

即：**面板不是常驻程序**。空闲达到 `UnloadDelay`（默认 300 秒 = 5 分钟）后 UI 被卸载；下次呼出需要重建外壳、加载页面组件、重连数据模型。用得勤（5 分钟内反复呼出）时它是热的，所以表现成"偶尔"。

> ⚠️ **注意**：更新/重装显卡驱动时会重新导入 `cn.reg`，因此任何对 `HKLM\SOFTWARE\AMD\CN` 的改动都会**被驱动更新重置**，需要重新应用。

---

## 7. 缓解与恢复

### 7.1 保活（推荐先做，风险最低）

把上面两个生命周期值调大，让面板长期保持"热"：

| 位置（`HKLM\SOFTWARE\AMD\CN`） | 出厂默认 | 建议值 | 作用 |
|---|---|---|---|
| `UnloadDelay` (REG_DWORD, 秒) | `300` (`0x12c`) | `86400`（24h）或先试 `3600` | 空闲多久才卸载 UI |
| `MemorySizeTreshold` (REG_DWORD, MB) | `200` (`0xc8`) | `512` ~ `1024` | 抬高内存维度触发卸载的门槛 |

**必须两个一起改**：只拉长 `UnloadDelay` 而不抬 `MemorySizeTreshold`，可能照样被内存路径卸掉。

命令（管理员 CMD）：

```bat
reg add "HKLM\SOFTWARE\AMD\CN" /v UnloadDelay        /t REG_DWORD /d 86400 /f
reg add "HKLM\SOFTWARE\AMD\CN" /v MemorySizeTreshold /t REG_DWORD /d 1024  /f
```

- **生效时机**：面板下次启动时读取，无需重启电脑。
- **代价**：面板进程常驻会占用内存（量级几百 MB），自行取舍。
- 现成的应用/回滚脚本见 [`scripts/`](scripts/) 与 [附录 C](#附录-c-脚本)。

**不要动**这几个：`PreloadDelay` / `Win11PreloadDelay` / `LazeStart`。它们甚至不在注册表里（走代码默认），语义未经证实，改了属于盲猜。

### 7.2 卡住时的恢复阶梯

`cncmd.exe` 同时是启动器和看门狗，自带现成命令。**先跑一次 `cncmd.exe help` 自行核对**（纯打印，无副作用）：

```
命令格式： Cncmd <message> [<component>]    或   Cncmd <options>

messages  : show   hide   hideall   exit   pause   resume   glinfo   help
options   : startwithdelay   restart   restartandshow   help
components: launcher   display_app   workstation_app   <各 *_ui_component>
```

按侵入性从低到高：

| 步骤 | 命令 / 操作 | 适用场景 |
|---|---|---|
| 1 | 再按一次 `Alt+R`（隐藏再唤出） | 最轻的一次重新加载 |
| 2 | `cncmd.exe show` | 让已有实例重新显示/补齐，不重启进程 |
| 3 | `cncmd.exe resume` | 面板被挂起后只剩空壳（对应 `Resume request ... when not-paused` 那条状态机） |
| 4 | `cncmd.exe restartandshow` | **卡死了要重来时的正确做法**：官方语义即 "Restarts and Shows CNext App"，且不会打乱看门狗状态 |
| 5 | 任务管理器结束 `RadeonSoftware.exe` → `cncmd startwithdelay` | 进程假死 |
| 6 | 重启系统 | 兜底 |

完整路径：`"C:\Program Files\AMD\CNext\CNext\cncmd.exe"`

> 先判断是哪一种：任务管理器里看 `RadeonSoftware.exe` 是否在、**CPU 是否在动**。
> CPU 有一两秒持续占用 = 在加载（等它）；CPU 接近 0 且久不变 = 预加载分支失败（走第 3~5 步）。

### 7.3 降低触发概率

以下都是**降低概率**的措施，不是根因修复：

1. **收尾安装器状态**。若曾出现 `MsiInstaller` 事件 `11729`（例如 `Product: AMD User Experience Program -- Configuration failed.`），说明有组件的事务状态不干净；配合 AMD Install Manager 挂起的自更新与自动更新（`HKLM\SOFTWARE\AMD\AMDInstallManager\AutoUpdate\KeepUpToDate=1`），后台 MSI 重配置会和 UI 启动抢资源、动组件。要么让它装完，要么关掉后台自动更新，并在「程序和功能」里对相应 AMD 组件做一次"修复"。
2. **第三方虚拟显示适配器**。多一块虚拟显示器就多一类显示拓扑变化，可能触发上面的 `RestoreToFactory` 视图切换重启甚至 `EXIT_FOR_GPU_LOST`。不用远程/串流时禁用它。
3. **游戏姿态**。尽量用无边框全屏而非独占全屏；不要在游戏启动/退出/切桌面的瞬间按热键。
4. **精简常驻叠加层**。外设/主板厂商的常驻套件、Steam、WebView2 宿主等会往其它进程注入 hook，是"窗口在但内容空白/发黑"的常见共犯。
5. **开机后等一分钟再呼出**。面板本身就是登录后延迟 `InitDelay`(60s) 才预热，开机头一分钟系统最忙。

### 7.4 打开面板自诊断日志（待验证）

面板的自身日志**默认是关闭的**——所以这类失败不留痕迹。相关键名与文件名规则来自二进制：

```
注册表键 : HKLM\SOFTWARE\AMD\CN\LOG
值名     : log_minpriority / log_destination / log_component_ids
产物     : %s\cnlog%s.txt
```

打开后，复现时就能直接看到具体卡在哪一步（`Can't preload X. View creation failed.` 还是 `ConnectModel failed.`）。

> ⚠️ 值的**取值语义未经证实**（仅键名/值名来自二进制字符串）。建议从 `log_minpriority=0` 开始试，或用同名环境变量代替。开启前请自行评估日志体积与隐私内容。

---

## 8. 自检：怎么确认保活真的生效

| | 改之前（出厂默认） | 改之后（期望） |
|---|---|---|
| 关闭面板窗口后 | 约 **5 分钟内**进程消失 | **一直挂着**（空闲 24h 才卸载） |
| 下次按 `Alt+R` | 冷启动：外壳先出、内容要等 | 热的：内容几乎立刻到位 |

**最有说服力的验证**：打开面板一次 → 等 10 分钟 → 回任务管理器看 `RadeonSoftware.exe` 是否还在。老行为下它早没了。

**如果它仍然几分钟就消失**，说明 `UnloadDelay` 不是控制这条路径的开关（还可能存在 `EXIT_FOR_GPU_LOST` 或内存判定等其它退出路径）。此时不要再猜，按 [§7.4](#74-打开面板自诊断日志待验证) 打开日志，让面板自己写出它走了哪条路。

查看当前值：

```bat
reg query "HKLM\SOFTWARE\AMD\CN" /v UnloadDelay
reg query "HKLM\SOFTWARE\AMD\CN" /v MemorySizeTreshold
:: 期望 0x15180 与 0x400
```

---

## 9. 回滚

```bat
reg add "HKLM\SOFTWARE\AMD\CN" /v UnloadDelay        /t REG_DWORD /d 300 /f
reg add "HKLM\SOFTWARE\AMD\CN" /v MemorySizeTreshold /t REG_DWORD /d 200 /f
```

恢复到 `cn.reg` 里的出厂值，面板重新变成"空闲 5 分钟即卸载"。见 [`scripts/rollback-keepalive.cmd`](scripts/rollback-keepalive.cmd)。

---

## 10. 尚未证实的部分（诚实声明）

写清楚哪些是**结论**、哪些是**推断**，避免误导：

| 结论 | 置信度 | 依据 |
|---|---|---|
| 面板是 Qt6/QML 应用，采用"外壳先出、内容异步预加载"两阶段结构 | **高** | 二进制字符串 + 资源路径 + 类型名 |
| 内容预加载失败时程序保留外壳继续显示、不崩溃 | **高** | 十余条专用错误分支字符串 |
| `UnloadDelay` 是空闲卸载延时、默认 300 秒 | **高** | `cn.reg` 默认值 + 代码读取与校验字符串 |
| `MemorySizeTreshold` 按私有工作集决定是否卸载 | **中** | 与 `Failed to get private working set size` 同处卸载路径；**单位与判定方向未实测** |
| `LOG` 键名及其产物 `cnlog*.txt` | **中** | 键名来自二进制；**取值语义未验证** |
| `cncmd` 命令表 | **中** | 来自二进制帮助表；**未逐一实测，请先跑 `cncmd.exe help`** |
| 上述保活改动能消除症状 | **待验证** | 注册表层已核实写入；**行为层需按 [§8](#8-自检怎么确认保活真的生效) 自测** |
| RSX 会话日志文件名 = 进程启动时刻 | **已被推翻** | 后续观测到多次面板启动但未生成新日志文件；该文件更接近"每次开机后首次启动"生成 |

---

## 11. 诊断方法备忘（可复用）

1. **先分"慢"和"死"再动手**。看 CPU 是否在动，决定是等它还是重启它。这两种情况的处置完全不同。
2. **不要只信一个信号**。判断"某进程是否在运行"时，进程列表、`tasklist`、性能计数器、文件占用探针可能因权限/沙箱而失真。
3. **探针一定要有对照组**。例如判断"文件是否被占用"时，同时探测一个确定不会被占用的文件；若它也失败，说明失败原因是权限而不是占用。本病例中这一步避免了一次误判（`UnauthorizedAccessException` ≠ 共享冲突）。
4. **厂商程序的自诊断默认常常是关的**。先确认日志开关状态，再决定"为什么没有证据"。
5. **静态取证很有用**。UI 框架、错误分支、生命周期开关、内部命令表，往往直接以字符串形式躺在二进制里。

复现本文的字符串取证（只读，PowerShell）：

```powershell
$f = 'C:\Program Files\AMD\CNext\CNext\RadeonSoftware.exe'
$b = [IO.File]::ReadAllBytes($f)
$a = [Text.Encoding]::ASCII.GetString($b)
[regex]::Matches($a, "Can't preload [\x20-\x7E]{0,70}") | ForEach-Object Value | Sort-Object -Unique

# UTF-16 区段里存放的是注册表值名/配置表
$u = [Text.Encoding]::Unicode.GetString($b)
[regex]::Matches($u, '(UnloadDelay|PreloadDelay|Win11PreloadDelay|LazeStart|MemorySizeTreshold)') |
    ForEach-Object Value | Sort-Object -Unique
```

---

## 附录 A：证据清单

| # | 事实 | 证据 |
|---|---|---|
| 1 | 面板是 Qt 6.9 + QML + QtWebEngine 应用 | 安装目录含 Qt6 全套与 `QtWebEngineProcess.exe`；缓存目录 `_qt_QGfxShaderBuilder_6.9.0`；`cncmd.exe` 内含 `qt_version_tag_6_9` |
| 2 | 双阶段外壳 + 隐藏预加载窗口 | `UI_Common::HiddenPreloadWindow`、`qrc:/Qml/Common/PreloadWindow.qml`、`Preload Shell Start/End: %1`、`hidden_preload_component` |
| 3 | 预加载失败时保留外壳、不崩溃 | `Can't preload %1. Bad state / View creation failed / ConnectModel failed / Model creation failed / Can't find shell's context / VIEW / canvas`、`Failed to wait for all UI preload finish.`、`Component is not ready.` |
| 4 | 存在暂停/恢复状态机及竞态告警 | `Pause request was recieved to already paused process.`、`Resume request was recieved when not-paused.` |
| 5 | 视图切换会重启进程且期间不显示 UI | `RestoreToFactory is called for view switch. Will restart process, no UI shown after.` |
| 6 | 生命周期开关与出厂默认值 | `cn.reg`：`UnloadDelay=0x12c(300)`、`MemorySizeTreshold=0xc8(200)`、`InitDelay=0x3c(60)`；代码默认 `Preload Delay ... 300`、`Unload Delay ... Setting it to 1800.` |
| 7 | 内存感知卸载 | `Failed to get private working set size`（与卸载路径同段） |
| 8 | 启动链 | `StartCN.xml` → `cncmd.exe startwithdelay` |
| 9 | 看门狗与退出码 | `cncmd.exe`：`WatchRsx()`、`RSX exit unexpectedly, attempt recovery / will not recover`、`EXIT_FOR_GPU_LOST(_SILENT)`、`EXIT_FOR_MEMORY_EXCEPTION`、`LastRecoveryTime` / `LastRecoveryCount` |
| 10 | 不是崩溃、不是驱动 TDR | WER 无相关记录；系统日志无 `Display` 4101 类事件；无 `Application Error`/`Application Hang` |
| 11 | 看门狗从未记录过恢复 | `SOFTWARE\AMD\CN` 下 `LastRecoveryTime` / `LastRecoveryCount` 均不存在 |
| 12 | 面板自诊断默认关闭 | `HKLM\SOFTWARE\AMD\CN\LOG` 不存在，全盘无 `cnlog*.txt`（文件名规则 `%s\cnlog%s.txt`） |

---

## 附录 B：速查表

| 用途 | 路径 / 命令 |
|---|---|
| 面板主程序 | `C:\Program Files\AMD\CNext\CNext\RadeonSoftware.exe` |
| 启动器 / 看门狗 | `C:\Program Files\AMD\CNext\CNext\cncmd.exe` |
| 出厂默认值模板 | `C:\Program Files\AMD\CNext\CNext\cn.reg` |
| 登录启动任务定义 | `C:\Program Files\AMD\CNext\CNext\StartCN.xml` |
| 生命周期开关 | `HKLM\SOFTWARE\AMD\CN` → `UnloadDelay` / `MemorySizeTreshold` / `InitDelay` |
| 面板自诊断日志开关 | `HKLM\SOFTWARE\AMD\CN\LOG` |
| 用户侧 UI 状态 | `HKCU\SOFTWARE\AMD\CN` → `ResumeLastPage` / `LastPage` / `WindowSize` / `SidebarWidth` |
| 面板热键 | `HKLM\SOFTWARE\AMD\DVR` → `ToggleRsHotkey="Alt,R"`、`ToggleRsPerfUiHotkey="Ctrl+Shift,O"` |
| 用户侧数据/缓存 | `%LOCALAPPDATA%\AMD\CN\`、`%LOCALAPPDATA%\AMD\Radeonsoftware\cache\` |
| QML 组件缓存 | `%LOCALAPPDATA%\AMD\Radeonsoftware\cache\qmlcache\*.qmlc` |
| 会话日志 | `%LOCALAPPDATA%\AMD\CN\RSX_Common.log_<日期>_<时间>.log` |

---

## 附录 C：脚本

完整脚本见 [`scripts/apply-keepalive.cmd`](scripts/apply-keepalive.cmd) 与 [`scripts/rollback-keepalive.cmd`](scripts/rollback-keepalive.cmd)。
两者都会**自动检测管理员权限并请求 UAC 提权**（用 `S-1-16-12288` 判断管理员令牌，与系统语言无关），并在写入前后各回读一次注册表，最后暂停以便查看结果。

<details>
<summary>展开：apply-keepalive.cmd</summary>

```bat
@echo off
rem  AMD Radeon Software 面板 "保活" 设置  --  只改这两个值
rem  目标键 : HKLM\SOFTWARE\AMD\CN
rem  改前   : UnloadDelay=300 (0x12c)   MemorySizeTreshold=200 (0xc8)   <- cn.reg 出厂默认
rem  改后   : UnloadDelay=86400 (0x15180)   MemorySizeTreshold=1024 (0x400)
rem  生效   : 面板下次启动时读取, 无需重启电脑
rem  回滚   : rollback-keepalive.cmd
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
echo [OK] Done. New values apply at the next panel launch. No reboot needed.
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
```

</details>

> 提示：`.cmd` 文件必须使用 **CRLF** 行尾。若通过某些编辑器/工具生成后行尾变成 LF，`goto` 与多行 `if` 块可能解析异常。

---

## 免责声明

- 本文是基于**二进制静态取证 + 系统状态读取**的独立分析，与 AMD 无关，**不是官方修复**。
- 修改 `HKLM` 注册表需要管理员权限，且**可能被驱动更新重置**。请先备份/记录原值，并在理解风险后自行决定是否应用。
- AMD 未公开这些配置项，其语义由字符串与行为推断而来；不同驱动版本可能变化。
