' Scan-Relay silent launcher / 静默启动中转服务
' Started by the scanrelay:// protocol or by desktop / start-menu shortcuts.
' ASCII-only on purpose: wscript reads .vbs in the ANSI codepage (GBK), so no CJK here.
'
' Behavior:
'   1) Probe http://127.0.0.1:8765/healthz -- exit silently if the relay is already up.
'   2) Otherwise start "<own dir>\server\relay.py" in a MINIMIZED console window,
'      stdout/stderr appended to %LOCALAPPDATA%\Scan-Relay\relay.log.
' The minimized window stays in the taskbar on purpose: closing it stops the service.

Option Explicit
Dim sh, fso, http, root, serverDir, logDir, logFile, cmd, status

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Resolve own directory -> works no matter where the zip is extracted (incl. CJK paths).
root = fso.GetParentFolderName(WScript.ScriptFullName)
serverDir = fso.BuildPath(root, "server")

If Not fso.FolderExists(serverDir) Then
  sh.Popup "Scan-Relay server folder not found:" & vbCrLf & serverDir & vbCrLf & vbCrLf & _
           "Keep launcher.vbs next to the server folder.", 0, "Scan-Relay", 48
  WScript.Quit 1
End If

' 1) already running?
status = ""
On Error Resume Next
Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
http.setTimeouts 1000, 1000, 2000, 2000
http.Open "GET", "http://127.0.0.1:8765/healthz", False
http.Send
If Err.Number = 0 Then status = CStr(http.Status)
Err.Clear
On Error GoTo 0
If status = "200" Then WScript.Quit 0  ' already up, nothing to do

' 2) start relay in a minimized console, log to file
logDir = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Scan-Relay"
If Not fso.FolderExists(logDir) Then fso.CreateFolder(logDir)
logFile = fso.BuildPath(logDir, "relay.log")

cmd = "cmd /c cd /d """ & serverDir & """ && python relay.py >> """ & logFile & """ 2>&1"
' WindowStyle 2 = minimized; wait=False -> launcher exits immediately
sh.CurrentDirectory = serverDir
sh.Run cmd, 2, False
