; ============================================================================
; Scan-Relay 安装脚本（Inno Setup 6.3+，本机构建用 6.7.3）
;
; 三条贯穿全文的约束，改动前请先读：
;
;   1. **全程 per-user，不请求管理员权限**（PrivilegesRequired=lowest）。
;      Office 的 TrustedCatalogs 与 scanrelay:// 协议都写在 HKCU 下，本来就
;      不需要管理员；安装目录取 %LOCALAPPDATA%\Programs\Scan-Relay，同样免提权。
;      代价是只对当前用户生效 —— 这正是想要的，中转服务本来就是单机自用。
;
;   2. **安装/卸载前必须先停掉正在跑的服务**（见 PrepareToInstall /
;      CurUninstallStepChanged）。relay.py 由 python.exe 加载着，不停就直接覆盖
;      会失败，或者留下一半新一半旧的文件。
;
;   3. **TrustedCatalogs 的 Url 必须是 UNC 共享文件夹，不是 manifest 文件**。
;      这是 Excel 侧载的硬性要求，见 README「Excel 侧载的历史坑」。这里借用
;      管理共享 \\localhost\C$——当前用户永远有权读自己的目录，免去新建共享+授权。
; ============================================================================

#define MyAppName "Scan-Relay"
// 版本号允许被命令行覆盖：build-release.ps1 会传 /DMyAppVersion=x.y.z。
// 若不加 #ifndef 守卫，脚本内的 #define 会静默顶掉传入值，导致改了版本号
// 却输出旧文件名、且 AppVersion 与文件名对不上。
#ifndef MyAppVersion
  #define MyAppVersion "1.3.0"
#endif
#define MyAppPublisher "Scan-Relay contributors"
#define MyAppURL "https://github.com/scan-relay/scan-relay"
; 固定 GUID：与 sideload.ps1 里已生效的目录一致，重复安装只更新同一条，不会越积越多
; GUID 本身**不带花括号**定义，因为 Inno 把 `{...}` 当作自己的常量语法：
; 若直接在 #define 里写成带花括号的形式，宏展开后会得到 `{43d8e154-...}`，
; 下一阶段的常量解析会把它误报为 Unknown constant（必须用 `{{` 才能得到字面 `{`）。
; 但注册表键名和 Id 值又确实需要花括号（Office 侧载要求，见 sideload.ps1），
; 所以在这里组装一份带花括号的。
#define CatalogGuid "43d8e154-b154-47b6-b16e-2188d640be71"
#define CatalogBraced "{{" + CatalogGuid + "}"

[Setup]
; AppId 固定，升级时覆盖安装而不是并排装两份
AppId={{8F3C2E1A-5D4B-4C6E-9A71-2B0D4E6F8C31}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}

DefaultDirName={localappdata}\Programs\{#MyAppName}
DisableProgramGroupPage=yes
; per-user：不写 HKLM、不写 Program Files，全程无 UAC 弹窗
PrivilegesRequired=lowest

; x64compatible 需要 Inno 6.3+；内嵌 Python 只有 win_amd64，装在 32 位模式下也没意义
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

OutputDir=..\dist
OutputBaseFilename=Scan-Relay-Setup-{#MyAppVersion}
SetupIconFile=..\dist\standalone\assets\icon.ico
UninstallDisplayIcon={app}\assets\icon.ico
UninstallDisplayName={#MyAppName}

Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 装完显示 README 片段：「重启 Excel/Word/PPT 才能看到加载项」是最常见的求助原因
InfoAfterFile=..\dist\standalone\assets\install-notes.txt

[Languages]
Name: "zh"; MessagesFile: "compiler:Default.isl"

; 刻意不设 [Types]/[Components]：这个安装包只装一样东西，没有可勾选的子集，
; 为此引入组件选择页只是平白多一页 UI 和一堆要维护的 `Components: app` 引用。

[Files]
; ---- 内嵌 Python 运行时（由 packaging\fetch-python.ps1 组装）----
Source: "..\dist\standalone\python\*"; DestDir: "{app}\python"; \
    Flags: recursesubdirs createallsubdirs ignoreversion

; ---- 中转服务与托盘 ----
; Excludes 必须挡掉 .certs：那是 relay.py 生成的**私钥**，绝不进安装包
Source: "..\server\*"; DestDir: "{app}\server"; \
    Excludes: ".certs\*,__pycache__\*,*.log,*.pid"; \
    Flags: recursesubdirs createallsubdirs ignoreversion

; ---- 加载项：relay.py 按 `<server 的上级>/addin/dist` 找构建产物，
;      所以目录名 addin 不能改 ----
Source: "..\addin\manifest.xml"; DestDir: "{app}\addin"; Flags: ignoreversion
Source: "..\addin\dist\*"; DestDir: "{app}\addin\dist"; \
    Flags: recursesubdirs createallsubdirs ignoreversion

; ---- 托盘图标（快捷方式与控制面板都用它）----
Source: "..\dist\standalone\assets\icon.ico"; DestDir: "{app}\assets"; Flags: ignoreversion

; ---- 文档 ----
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.en.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："

[Icons]
; 托盘程序本身就是入口：双击 -> 拉起中转服务 + 弹「中转服务已启动」+ 通知区域出现图标
; 用 pythonw.exe（GUI 子系统）而不是 python.exe，否则会闪一个黑色控制台窗口
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\python\pythonw.exe"; \
    Parameters: """{app}\server\tray.py"""; IconFilename: "{app}\assets\icon.ico"; \
    WorkingDir: "{app}"; Comment: "启动 Scan-Relay 中转服务并显示任务栏图标"; Tasks: desktopicon
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\python\pythonw.exe"; \
    Parameters: """{app}\server\tray.py"""; IconFilename: "{app}\assets\icon.ico"; \
    WorkingDir: "{app}"; Comment: "启动 Scan-Relay 中转服务并显示任务栏图标"

[Registry]
; ---- Excel/Word/PPT 侧载目录（HKCU，无需管理员）----
; Url 指向**文件夹**的 UNC，不是 manifest 文件本身
Root: HKCU; Subkey: "Software\Microsoft\Office\16.0\Wef\TrustedCatalogs\{#CatalogBraced}"; \
    ValueType: string; ValueName: "Id"; ValueData: "{#CatalogBraced}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Office\16.0\Wef\TrustedCatalogs\{#CatalogBraced}"; \
    ValueType: string; ValueName: "Url"; ValueData: "{code:CatalogUnc}"
Root: HKCU; Subkey: "Software\Microsoft\Office\16.0\Wef\TrustedCatalogs\{#CatalogBraced}"; \
    ValueType: dword; ValueName: "Flags"; ValueData: 1

; ---- scanrelay:// 协议：任务窗格里的「一键启动服务器」按钮靠它唤起托盘 ----
Root: HKCU; Subkey: "Software\Classes\scanrelay"; \
    ValueType: string; ValueName: ""; ValueData: "URL:Scan-Relay Launcher"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\scanrelay"; \
    ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\scanrelay\shell\open\command"; \
    ValueType: string; ValueName: ""; \
    ValueData: """{app}\python\pythonw.exe"" ""{app}\server\tray.py"" ""%1"""

[Run]
; 装完可选立即启动。这是**一次性**启动，不是开机自启 —— 按需求：不写 Startup、
; 不注册登录任务，之后服务是否运行完全由用户通过托盘图标手动控制。
Filename: "{app}\python\pythonw.exe"; Parameters: """{app}\server\tray.py"""; \
    Description: "启动 Scan-Relay"; Flags: nowait postinstall skipifsilent; \
    WorkingDir: "{app}"

[UninstallDelete]
; 运行期产生的文件，安装清单里没有，Inno 不会自动删
Type: filesandordirs; Name: "{app}\server\.certs"
; Python 在安装目录里写出的字节码缓存。正常运行时 tray.py/relay.py 都是**以脚本方式**
; 执行（脚本不产生 __pycache__），所以平时不会有；但只要有代码 import 了它们
; （比如用安装目录里的解释器跑自检脚本），server\__pycache__ 就会出现 ——
; 不删的话残留目录会让 Inno 连 {app}\server 和 {app} 一起留下。
Type: filesandordirs; Name: "{app}\server\__pycache__"
Type: filesandordirs; Name: "{app}\python\__pycache__"
Type: filesandordirs; Name: "{localappdata}\Scan-Relay"

[Code]
{-----
  把本地路径转成 \\localhost\C$... 形式的 UNC。
  TrustedCatalogs 的 Url 必须是 UNC 共享目录；借用管理共享可以免去「新建共享 + 授权」
  这一整套动作，而当前用户读自己的 %LOCALAPPDATA% 是必然有权限的。
-----}
function CatalogUnc(Param: String): String;
var
  AppDir, Rest: String;
begin
  AppDir := ExpandConstant('{app}');
  Rest  := Copy(AppDir, 3, MaxInt);                 // '\Users\ee\AppData\...'
  Result := '\\localhost\' + AppDir[1] + '$' + Rest + '\addin';
  Log('TrustedCatalogs Url -> ' + Result);
end;

{-----
  卸载/升级前的清理：停服务 **并退出托盘**。

  必须发 quit 而不是 stop —— 这是实测出来的：只发 stop 时卸载器返回成功，
  却在安装目录留下半截 python\\ 和 server\\。原因是托盘以 pythonw.exe 常驻，
  它运行期间其映像被系统以共享写保护锁定，DeleteFile 会撞 sharing violation。

  quit 内部先走 /shutdown HTTP 端点（旧 launcher.vbs 起的服务没有托盘，
  那种情况走 PID 文件兜底），再按 tray.pid 精确 taskkill 托盘并等它真死，
  所以 Exec 返回时进程必然已退出 —— 这也让后面的文件删除是确定性的。

  托盘不存在（首次安装）时整个分支跳过。
-----}
procedure StopRelayIfRunning();
var
  Rc: Integer;
  Pyw, Tray: String;
begin
  Pyw  := ExpandConstant('{app}\python\pythonw.exe');
  Tray := ExpandConstant('{app}\server\tray.py');
  if FileExists(Pyw) and FileExists(Tray) then
  begin
    Exec(Pyw, '"' + Tray + '" scanrelay://quit', ExpandConstant('{app}'),
         SW_HIDE, ewWaitUntilTerminated, Rc);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  // 覆盖安装前必须先停服务：python.exe 正在执行时，它和它的依赖 DLL 都被占用，
  // 直接覆盖会失败或留下半新半旧的文件。
  StopRelayIfRunning();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Thumb: String;
  Rc: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    // 先停服务再删文件，否则正在运行的 python.exe 会让文件删除失败
    StopRelayIfRunning();
  end
  else if CurUninstallStep = usPostUninstall then
  begin
    // 清掉 relay.py 生成并装进「当前用户受信根目录」的 localhost 自签名证书。
    // 不清的话反复安装/卸载会越积越多条废证书：.certs 目录随 {app} 一起被删，
    // 下次启动 relay.py 又会生成一张新的、再装一条进根证书存储。
    Thumb := '';
    if RegQueryStringValue(HKCU, 'Software\Scan-Relay', 'LocalhostCertThumbprint', Thumb)
       and (Thumb <> '') then
    begin
      if Exec(ExpandConstant('{sys}\certutil.exe'), '-user -delstore Root ' + Thumb, '',
              SW_HIDE, ewWaitUntilTerminated, Rc) then
        Log('已移除 localhost 根证书 ' + Thumb)
      else
        Log('移除 localhost 根证书失败 (thumbprint=' + Thumb + ')');
    end;
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Scan-Relay');
  end;
end;
