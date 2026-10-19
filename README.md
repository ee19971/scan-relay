# Scan-Relay —— 手机扫码实时写入 Office（类 Scan-IT to Office）

手机摄像头扫码 / 表单采集 → 局域网中转服务 → Office 加载项实时写入 **Excel / Word / PowerPoint**。

[English](README.en.md) · [GPL-3.0](LICENSE)

```
┌─────────────┐   ws://局域网IP:8765   ┌──────────────────┐   wss://localhost:4443/relay   ┌─────────────────┐
│ 手机 App     │ ───────────────────► │  Python 中转服务  │ ◄────────────────────────────  │ Office JS 加载项 │
│ (Flutter)   │   扫码/表单数据        │  (FastAPI+WS)    │   （页面由中转服务直接托管）    │ (Excel/Word/PPT) │
└─────────────┘                       └──────────────────┘                    └────────┬────────┘
      ▲ 扫 QR / 手动输入配对地址              │ 自动探测局域网 IP                          │ 按宿主分流写入
      └──────────────────────────────────────┴─────────────────────────────────────► 单元格 / 光标处 / 文本框
```

## 目录

- `server/` —— 本地中转服务（配对、会话、WebSocket 转发）
- `addin/`  —— Office JS 加载项（配对二维码、连续扫码、表单设计器）
- `mobile/` —— Flutter 手机 App（Android / iOS，扫码配对 + 采集）
- `packaging/` —— 安装包构建（Inno Setup + 内嵌 Python 运行时）
- `docs/`   —— 补充文档

## 快速开始

### 安装（推荐，日常使用）

下载 Release 里的 `Scan-Relay-Setup-x.y.z.exe`，双击安装即可 —— **全程免管理员权限，无 UAC 弹窗**：

- 装到 `%LOCALAPPDATA%\Programs\Scan-Relay`（只对当前用户生效）
- 自动注册成 Excel/Word/PPT 的「受信任的加载项目录」
- 注册 `scanrelay://` 协议（任务窗格的「一键启动服务器」按钮靠它唤起服务）
- 创建桌面与开始菜单图标

装完**完全退出** Excel/Word/PPT 再打开（右下角托盘里可能还留着 Office 后台进程，那里也要退出），
然后「开始 → 加载项 → 我的加载项 → 共享文件夹」里就能看到 Scan-Relay。

### 启停方式

```
双击桌面/开始菜单「Scan-Relay」图标
  → 启动中转服务 + 弹「中转服务已启动」通知 + 任务栏通知区域出现图标

托盘图标右键 → 打开加载页面 / 发送剪贴板到文档 / 启动·重启中转服务 / 查看日志 / 退出
         单击 → 直接打开加载页面
```

服务本身以**无可见窗口**的方式运行，没有窗口可供误关。停止的正路是托盘右键「退出」
（或任务窗格里的停止，等价于 `scanrelay://stop`）。停止接口只接受 `127.0.0.1`，
局域网内的手机无法停掉服务。

> **没有任何开机自启**：不写 Startup、不注册登录任务，服务是否运行完全由你手动决定。
>
> **托盘图标找不到**：Windows 默认把新出现的托盘图标折叠进「显示隐藏的图标」（^ 小箭头）。
> 点开那个箭头，把 Scan-Relay 拖出来常驻即可 —— 只需拖一次，之后一直显示。
>
> **服务挂了怎么办**：任务窗格里的「服务器状态卡」每 3 秒探测一次，停止时显示 **🚀 一键启动服务器** 按钮，点击即通过 `scanrelay://` 协议唤起托盘拉起服务（系统会弹一次「是否打开」确认），服务恢复后窗格自动重连。服务彻底停止时 Office 连窗格都打不开（表现为"无法启动加载项"），此时双击桌面图标即可恢复。
>
> 端口说明：加载项页面默认端口是 **4443** 而非常见的 3000——3000 等低端口常被 Hyper-V/WinNAT 动态保留（`netsh int ipv4 show excludedportrange protocol=tcp` 可查看），表现为"端口被占用但 netstat 看不到占用者"（bind 报 WinError 10013）。如需改端口：设置 `RELAY_UI_PORT` 环境变量并同步修改 `addin/manifest.xml` 里的全部 URL，然后重新安装。

### 把剪贴板内容直接写进文档

托盘右键「**发送剪贴板到文档**」会把当前剪贴板文本按一条扫码消息推给所有已打开的
加载项窗口，效果与扫码完全一致（多列自动分列、重复保护、流式模式的追加行为都照常生效）。

- 手机没连、甚至没配对也能用 —— 这条链路完全在本机
- 只在**流式模式**下生效；表单模式的窗口会被忽略（表单模式由手机端按字段提交）
- 剪贴板超过 10000 字符会被截断，避免误复制一整篇文档时灌爆表格
- 托盘会弹通知告诉你发送了多少字符、到了几个窗口；没有任何窗口打开时会明确提示

### 手动启动（开发模式）

#### 1. 启动中转服务（电脑）

```powershell
cd server
pip install -r requirements.txt
python -m uvicorn relay:app --host 0.0.0.0 --port 8765
```

- 自动探测局域网 IP；如果探测不准，用环境变量覆盖：`$env:RELAY_HOST="192.168.x.x"`
- **Windows 防火墙**：首次运行会弹窗，选择"允许访问"（放行 TCP 8765），否则手机连不上

#### 2. 启动加载项开发服务器（电脑，仅改前端时需要）

```powershell
cd addin
npm install
npm start        # https://localhost:4443，首次会自动安装受信开发证书
```

改完前端代码后需 `npm run build` 重新构建，一键模式才会带上新界面。

### 3. 在 Office 中侧载加载项（Excel / Word / PowerPoint 通用）

**装了安装包的话这一步已经自动完成**：安装程序把 `%LOCALAPPDATA%\Programs\Scan-Relay\addin`
注册成「受信任的加载项目录」（写 `HKCU\Software\Microsoft\Office\16.0\Wef\TrustedCatalogs`，
无需管理员权限）。重启 Office 后即可：

1. 打开 Excel / Word / PowerPoint（桌面版）
2. **开始 → 加载项 → 我的加载项 → 共享文件夹**，选中 Scan-Relay
3. 首页「开始」选项卡会出现 **Scan-Relay → 扫码录入** 按钮，点击打开任务窗格
4. 点 **生成配对码**，显示二维码和连接状态

> 自用侧载无需 AppSource 审核。证书提示时选"是/安装"。
>
> **没装安装包、想手动侧载**：运行仓库里的 `sideload.ps1`（复制 manifest 到 `C:\ScanRelay`
> + 写受信任目录注册表 + 注册 `scanrelay://` 协议 + 创建快捷方式），或在
> **插入 → 加载项 → 我的加载项 → 上载我的加载项**里直接选 `addin/manifest.xml`。

### 各宿主写入行为

| 宿主 | 连续扫码 | 表单采集 |
|---|---|---|
| **Excel** | 自动跟踪选中单元格（点哪写哪），逐行追加 | 按列写入整行，行号自动跟随选中行 |
| **Word** | 插入到光标处，每条一段 | 按「字段名: 值」逐行插入到光标处 |
| **PowerPoint** | 追加到当前页「ScanRelay.Text」文本框（没有会自动创建） | 按「字段名: 值」逐行追加到当前页文本框 |

### 4. 手机端配对

```powershell
cd mobile
flutter run -d <设备>        # 或 flutter build apk 后 adb install
```

App 打开相机 → 扫 Excel 任务窗格里的二维码 → 状态变"已连接"即可开始采集。
（模拟器/无摄像头环境可在配对页手动输入 `http://IP:8765/scan?token=...`）

### 两种采集模式

| 模式 | 桌面端行为 | 手机端行为 |
|---|---|---|
| 连续扫码 | Excel：起点**自动跟踪选中单元格**（点哪写哪）逐行追加；Word/PPT：写到光标处/当前页文本框。均可设重复保护毫秒 | 对准条码自动逐条发送，支持手动输入/扫码枪 |
| 表单采集 | 设计字段（Excel 可指定列）→「下发配置到手机」 | 按配置渲染表单，填完「提交本行」写入 |

## 连接方式决策树（没有路由器/没网卡怎么办）

```
电脑有蓝牙？
 ├─ 有   → 蓝牙 HID 键盘模式（手机扫码直接"敲"进 Excel，零网络依赖，仅 Android）
 └─ 没有 → 电脑有 WiFi 或接了路由器？
      ├─ 有   → 主线：手机与电脑同一局域网，ws://<IP>:8765（上面的快速开始）
      └─ 没有 → 【USB 数据线】手机开"USB网络共享"
                电脑自动多出一块网卡，点对点连接，协议零改动
```

### USB 网络共享步骤（无蓝牙 + 无 WiFi 的台式机）

1. 手机用数据线连电脑，打开 **设置 → 网络 → USB 网络共享**（部分机型需先开移动数据或 WiFi 才允许开启）
2. Windows 通常自动装好驱动（内置 RNDIS/NCM），出现"以太网 N"网卡并拿到 `192.168.42.x` 地址
3. 防火墙首次弹窗选 **允许访问**
4. 生成配对码——服务会把**全部候选地址**列在任务窗格里；二维码用默认路由地址（USB 共享时通常已自动指向它），连不上就照窗格里的地址在手机上手动输入

> 手机热点同理：电脑连手机热点 → 同一局域网，连 D 都不需要。
> 注意：Android 的 **USB HID 键盘模式不可用**（需要系统权限/root），无网场景的正路只有 USB 共享。

## 蓝牙 HID 键盘模式（应急，无网络直写 Excel）

手机通过蓝牙把自己"伪装"成一个键盘：扫码结果像键盘敲击一样直接打进电脑上**任何有焦点的地方**（Excel 单元格、记事本、ERP 系统……）。
电脑端**零安装、零网络**——只要能开蓝牙就行，适合没有路由器 / 网卡被禁用的场景。仅支持 Android（iOS 系统不允许模拟键盘）。

### 使用步骤

1. 手机 App →「蓝牙键盘模式」→ 按引导完成 4 步：
   ① 授权蓝牙权限并打开蓝牙 → ② 启动键盘服务 → ③ 让电脑发现（5 分钟可发现窗口）
2. 电脑：`设置 → 蓝牙和其他设备 → 添加设备 → 蓝牙` → 选你的手机名 → **两端核对同一个 6 位数字后都点确认**
3. App 第 ④ 步变绿即成功。点「进入扫描页」，在 Excel 里先点中目标单元格，然后扫码

### 行为说明

- 每扫一条 → 自动敲入内容 + **回车换行**（连续追加多行）
- 只支持数字/字母/符号（HID 键盘协议没有中文按键）：中英混合只发送英文数字部分并提示；纯中文整条跳过并提示 → **中文内容请改用网络模式**
- 采集时保持 App 在前台，息屏/切后台可能导致蓝牙断连
- 配对只需一次，之后 App 启动服务时电脑会自动重连

### 配对失败排查（两端反复弹配对码 / AUTH_FAILURE）

根因几乎总是**双端残留的旧配对密钥不对称**（一端有、一端没有），必须**两端都删干净**再重配：

1. 电脑：设置 → 蓝牙和其他设备 → 找到手机 → 删除设备（`pnputil /remove-device` 需管理员权限；注册表密钥区 `BTHPORT\Parameters\Keys` 需 SYSTEM 权限，普通管理员读不到）
2. 手机：设置 → 蓝牙 → 已配对设备里的电脑 → 取消配对
3. 若手机配对弹窗一闪而过：MIUI/HyperOS 会压制反复弹出的配对窗（日志 `ignore the popupwindow`），等 2~3 分钟或重启手机再试
4. 重开 App 第②③步 → 电脑重新添加设备 → **两端及时确认**

> 已验证：小米 15 Pro（HyperOS）↔ Windows 11（Intel 无线蓝牙），配对一次后即开即用。
> 实现：自有 Kotlin `BluetoothHidDevice` 服务（标准 45 字节 boot 键盘描述符），MethodChannel `scanrelay/hid`，Android 9+。

## 测试工具（server/）

```powershell
python test_relay.py                 # 全链路自动化测试（配对/转发/配置/回收）
python fake_addin.py <token>         # 假加载项：打印手机发来的消息（联调用）
python send_config.py <token>        # 下发表单配置并监听提交（联调用）
```

浏览器调试入口：`http://<局域网IP>:8765/scan?token=<token>`（内置 jsQR 网页扫码器，无手机 App 也能测链路）。

## 构建安装包（发布者用）

```powershell
# 前置：node/npm、Python(含 Pillow)、Inno Setup 6.3+
powershell -ExecutionPolicy Bypass -File packaging\build-release.ps1
```

五步：构建加载项 → 组装内嵌 Python 运行时 → 生成图标与说明 → ISCC 编译 → 校验并复制到桌面。

安装包是**自包含**的：里面带着一份完整的内嵌 Python（由 `packaging\fetch-python.ps1` 组装），
所以目标机器既不需要 Python 也不需要 .NET，双击即用。

`packaging/` 各文件分工：

| 文件 | 作用 |
|---|---|
| `build-release.ps1` | 一键流程入口 |
| `fetch-python.ps1` | 下载 python.org 内嵌包 + 用 `pip --target` 交叉安装锁定版本的依赖 |
| `requirements-bundle.txt` | 内嵌运行时的依赖清单（比 `server/requirements.txt` 少了开发期才用的 extras） |
| `smoke.py` | 内嵌运行时自检：把 relay.py / tray.py 真正会用到的路径都跑一遍 |
| `make-ico.py` | 生成多尺寸 `.ico`（与加载项图标同款条码图案） |
| `scan-relay.iss` | Inno Setup 脚本 |
| `install-notes.txt` | 安装完成后展示的说明 |

> **构建机的一个坑**：Inno Setup 的官方安装包现在只发布在 GitHub Releases。
> 直连不可达时用镜像代理下载，但**下载后必须验签再执行** —— 代理只是搬运工，
> Authenticode 签名它伪造不了：
> ```powershell
> signtool verify /pa /v innosetup-x.y.z.exe     # Windows SDK 自带
> innosetup-x.y.z.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-
> ```
> 另外注意：`Get-AuthenticodeSignature` 在某些环境会因 PowerShell 模块冲突而不可用，
> 此时用 `signtool` 或直接读证书对象（`[Security.Cryptography.X509Certificates.X509Certificate]::new($path)`）。
> 判断签名者身份时别去匹配 `signtool` 的输出文本 —— 那是本地化的，中文机器上没有 `Subject:` 字样。

## 已验证

- [x] 中转服务全链路自动化测试（9 项断言全部通过）
- [x] 加载项 webpack 构建 + `/relay` 反向代理（含 WebSocket）
- [x] Android 模拟器端到端：扫码模式 `scan` 消息、表单模式 `form_submit` 消息均到达加载项端
- [x] 真机 Excel（M365 企业版）侧载成功，配对二维码 + 手机扫码链路跑通
- [x] 多宿主 manifest（Workbook/Document/Presentation + Office 1.1 通用要求集）
- [x] launcher.vbs 冷启动：`scanrelay://` 协议唤起 → 双端口 healthz 就绪（避开了 Hyper-V 保留段的 3000/3443）
- [x] 剪贴板注入端到端：`POST /inject`（仅回环地址）→ 伪造 `role=addin` 连接收到 `value`/`symbology=CLIPBOARD`/`source=clipboard`
- [x] 托盘日志回退：`relay.log` 被独占（cmd `>>` 重定向不共享写权限）时托盘日志落到 `tray.log`，且中转服务**仍能正常启动**（修复前会因写 banner 失败而直接放弃启动）

## 常见问题

- **手机连不上**：检查防火墙放行 8765；手机与电脑必须同一局域网（访客网络通常隔离）；`curl http://<IP>:8765/` 在手机浏览器能打开即通
- **加载项连不上**：先启动中转服务（任务窗格状态卡 / 桌面「Scan-Relay」图标 / 托盘右键「启动·重启中转服务」任选其一）
- **任务栏右侧找不到 Scan-Relay 图标**：Windows 默认把新出现的托盘图标折叠进「显示隐藏的图标」（^ 小箭头）。点开箭头，把图标拖出来常驻即可，只需拖一次。若彻底没有，说明服务还没启动过 —— 双击桌面「Scan-Relay」图标。
- **卸载后重装，https://localhost:4443 提示证书错误**：属正常，旧证书已随卸载清除，重新双击桌面图标让服务生成并安装新证书即可。
- **"端口被占用"但 netstat 看不到占用者**：多半是 Hyper-V/WinNAT 动态保留段吞了端口（bind 报 `WinError 10013`），`netsh int ipv4 show excludedportrange protocol=tcp` 可确认；默认端口已避开（8765/4443），若自定义端口中招则换端口或重启系统（保留段每次开机重新分配）
- **为什么加载项不直连 ws://局域网IP**：Office 加载项页面强制 HTTPS，直连 ws:// 会被 mixed-content 拦截；故经 `wss://localhost:4443/relay` 代理转发（见 `server/relay.py` 的 `/relay/*` 路由）
- **Excel 侧载的历史坑**（实测记录，供排查参考）：
  - `manifest.xml` 的 `<Version>` 必须 ≥ 1.0，否则 `office-addin-manifest validate` 报 "Manifest Version Too Low"，Excel 拒绝安装
  - 注册表侧载要用**当前官方格式**：`HKCU\Software\Microsoft\Office\16.0\Wef\TrustedCatalogs\{GUID}`，值为 `Id`（带花括号的 GUID）、`Url`（**指向共享文件夹而非 manifest 文件**，UNC 双反斜杠）、`Flags`=dword:1；写完需完全重启 Excel
  - 共享文件夹可用管理共享：`\\localhost\C$\ScanRelay`（当前用户可直接读）
  - 也可走 UI：文件 → 选项 → 信任中心 → 受信任的加载项目录
  - 界面入口：文件 → 账户 → 获取加载项 → **我的加载项**（不是应用商店）
- **任务窗格按钮全无反应**：office.js CDN（appsforoffice.microsoft.com）加载失败会导致面板 JS 死掉；当前代码已做 8 秒降级兜底（配对不依赖 Office API），日志会提示"已进入降级模式"
- **生成配对码无二维码**：若日志显示"图片 正常"但界面无码，检查是否旧版本 bug（connect() 误隐藏 qrBox，已修复）；日志显示"生成配对码失败"则是中转服务未启动
- **Flutter 中文路径**：已在 `mobile/android/gradle.properties` 加 `android.overridePathCheck=true`；`flutter analyze` 在中文路径下会因 Dart LSP 解析崩溃（环境 bug），用 `flutter build apk` 验证代码
  - **release 构建同样中招**：debug 构建不走 AOT 所以没事，`flutter build apk --release` 的 gen_snapshot 读取中文路径下的 `app.dill` 会报 "Unable to read file"（exit 255）。解法：用目录联接造一个纯 ASCII 路径再构建（内容同一份，无需复制）：
    ```powershell
    New-Item -ItemType Junction -Path C:\test\python\scanmobile -Target "C:\test\python\office插件\mobile"
    cd C:\test\python\scanmobile
    flutter build apk --release --split-per-abi   # 产物仍落在 mobile\build\ 下
    ```
- **permission_handler 版本**：锁 `^12.0.0`（13.x 要求 SDK 37.0 的目录命名与本机 AGP 不兼容）
- **相机权限被拒**：卸载重装会重置权限状态；App 内已提供「重试授权 / 打开系统设置」入口

## 产品化路线（预留）

- 中转服务传输层抽象为 `Transport` 接口：现阶段 `LocalTransport`（局域网），后续加 `CloudTransport`（自建云中继）解决手机与电脑跨网络，手机端与加载项端零改动
- AppSource 上架：manifest 补充图标/隐私政策，加载项页面改为固定 HTTPS 域名

## 隐私

- 全部数据只在**你自己的设备之间**流转（手机 → 电脑局域网/蓝牙），无任何云服务器、无统计上报、无第三方 SDK
- 中转服务只在本机内存中暂存会话，进程退出即清空；不写任何扫码数据到磁盘
- 电脑端蓝牙配对信息由 Windows 系统管理，App 不读取也不上传

## License

[GPL-3.0](LICENSE) · English: [README.en.md](README.en.md)
