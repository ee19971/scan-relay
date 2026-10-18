' Scan-Relay launcher / dispatcher
' Invoked by the scanrelay:// protocol, by desktop / start-menu shortcuts,
' or by the "start the server" button inside the Office task pane.
' ASCII-only on purpose: wscript reads .vbs in the ANSI codepage (GBK), so no CJK here.
'
' Usage:
'   launcher.vbs scanrelay://start         -> start the relay if it is down (silent)
'   launcher.vbs scanrelay://startverbose  -> same, but show a confirmation dialog
'                                             (used by the desktop/start-menu shortcut)
'   launcher.vbs scanrelay://stop          -> stop the relay
'   (no argument is treated as scanrelay://start)
'
' Start behavior:
'   1) Probe http://127.0.0.1:8765/healthz -- exit silently if the relay is already up.
'   2) Otherwise start "<own dir>\server\relay.py" with a HIDDEN window (window style 0),
'      stdout/stderr appended to %LOCALAPPDATA%\Scan-Relay\relay.log.
'      There is deliberately no taskbar window to close by accident -- the historical
'      "close the minimized window to stop the service" path used to kill the relay
'      behind the user's back (^C in relay.log, pane then failed to load at all).
'
' Stop behavior:
'   1) GET http://127.0.0.1:8765/shutdown  (loopback-only endpoint, graceful stop).
'   2) Wait up to 8 s for healthz to go away.
'   3) Fallback: taskkill the pid recorded in %LOCALAPPDATA%\Scan-Relay\relay.pid.

Option Explicit
Dim sh, fso, http, root, serverDir, logDir, logFile, pidFile, cmd, status
Dim action, verbose, i, pid

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Resolve own directory -> works no matter where the zip is extracted (incl. CJK paths).
root = fso.GetParentFolderName(WScript.ScriptFullName)
serverDir = fso.BuildPath(root, "server")
logDir = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Scan-Relay"
logFile = fso.BuildPath(logDir, "relay.log")
pidFile = fso.BuildPath(logDir, "relay.pid")

action = "start"
verbose = False
If WScript.Arguments.Count > 0 Then
  If InStr(1, LCase(WScript.Arguments(0)), "stop", vbTextCompare) > 0 Then
    action = "stop"
  End If
  If InStr(1, LCase(WScript.Arguments(0)), "verbose", vbTextCompare) > 0 Then
    verbose = True
  End If
End If

If action = "stop" Then
  WScript.Quit StopRelay()
Else
  WScript.Quit StartRelay()
End If


Function IsUp()
  ' True when http://127.0.0.1:8765/healthz answers 200
  status = ""
  On Error Resume Next
  Err.Clear
  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  http.setTimeouts 1000, 1000, 2000, 2000
  http.Open "GET", "http://127.0.0.1:8765/healthz", False
  http.Send
  If Err.Number = 0 Then status = CStr(http.Status)
  Err.Clear
  On Error GoTo 0
  If status = "200" Then
    IsUp = True
  Else
    IsUp = False
  End If
End Function


Function StartRelay()
  If IsUp() Then
    ' Service is invisible (no window), so double-clicking the start shortcut MUST
    ' tell the user something -- otherwise "nothing happened" looks like a failure.
    If verbose Then
      sh.Popup "Scan-Relay service is already running." & vbCrLf & vbCrLf & _
               "Add-in page: https://localhost:4443/taskpane.html" & vbCrLf & _
               "Stop it with the ""Stop Scan-Relay service"" shortcut." & vbCrLf & vbCrLf & _
               "Log: " & logFile, 8, "Scan-Relay", 64
    End If
    StartRelay = 0            ' already running, nothing to do
    Exit Function
  End If

  If Not fso.FolderExists(serverDir) Then
    sh.Popup "Scan-Relay server folder not found:" & vbCrLf & serverDir & vbCrLf & vbCrLf & _
             "Keep launcher.vbs next to the server folder.", 0, "Scan-Relay", 48
    StartRelay = 1
    Exit Function
  End If

  If Not fso.FolderExists(logDir) Then fso.CreateFolder(logDir)
  cmd = "cmd /c cd /d """ & serverDir & """ && python relay.py >> """ & logFile & """ 2>&1"
  sh.CurrentDirectory = serverDir
  ' Window style 0 = hidden (no taskbar entry, nothing to close by accident).
  sh.Run cmd, 0, False       ' wait=False -> this script exits immediately

  If verbose Then
    ' Give the relay a moment, then tell the user what happened.
    i = 0
    Do While (Not IsUp()) And i < 20
      WScript.Sleep 500
      i = i + 1
    Loop
    If IsUp() Then
      sh.Popup "Scan-Relay service is running." & vbCrLf & vbCrLf & _
               "Add-in page: https://localhost:4443/taskpane.html" & vbCrLf & _
               "Stop it with the ""Stop Scan-Relay service"" shortcut." & vbCrLf & vbCrLf & _
               "Log: " & logFile, 6, "Scan-Relay", 64
    Else
      sh.Popup "The service did not come up." & vbCrLf & vbCrLf & _
               "See the log for details:" & vbCrLf & logFile, 0, "Scan-Relay", 48
    End If
  End If

  StartRelay = 0
End Function


Function StopRelay()
  If Not IsUp() Then
    ' Not running -- just drop a stale pid file if one is left over.
    If fso.FileExists(pidFile) Then
      On Error Resume Next
      fso.DeleteFile pidFile, True
      On Error GoTo 0
    End If
    StopRelay = 0
    Exit Function
  End If

  ' 1) graceful stop (endpoint refuses non-loopback clients)
  On Error Resume Next
  Err.Clear
  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  http.setTimeouts 1000, 1000, 3000, 3000
  http.Open "GET", "http://127.0.0.1:8765/shutdown", False
  http.Send
  Err.Clear
  On Error GoTo 0

  ' 2) wait up to 8 s for healthz to disappear
  i = 0
  Do While IsUp() And i < 16
    WScript.Sleep 500
    i = i + 1
  Loop

  ' 3) fallback: kill the recorded pid when the event loop is wedged
  If IsUp() Then
    pid = ""
    If fso.FileExists(pidFile) Then
      On Error Resume Next
      pid = Trim(fso.OpenTextFile(pidFile, 1).ReadAll)
      Err.Clear
      On Error GoTo 0
    End If
    If pid <> "" And IsNumeric(pid) Then
      sh.Run "cmd /c taskkill /PID " & pid & " /T /F >> """ & logFile & """ 2>&1", 0, True
      WScript.Sleep 1500
    End If
  End If

  If IsUp() Then
    sh.Popup "Could not stop Scan-Relay." & vbCrLf & vbCrLf & "See the log:" & vbCrLf & logFile, _
             0, "Scan-Relay", 48
    StopRelay = 1
  Else
    If verbose Then
      sh.Popup "Scan-Relay service stopped.", 4, "Scan-Relay", 64
    End If
    StopRelay = 0
  End If
End Function
