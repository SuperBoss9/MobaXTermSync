' Launch a PowerShell -File script with no console window.
' Usage: wscript.exe //B //nologo Run-Hidden.vbs <script.ps1> [args...]
Option Explicit

If WScript.Arguments.Count < 1 Then
  WScript.Quit 1
End If

Dim shell, fso, ps, cmd, i, a
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

ps = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(ps) Then
  WScript.Quit 2
End If

cmd = """" & ps & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File"
For i = 0 To WScript.Arguments.Count - 1
  a = WScript.Arguments(i)
  cmd = cmd & " """ & Replace(a, """", """""") & """"
Next

' 0 = hide window; True = wait so Task Scheduler sees real exit code
WScript.Quit shell.Run(cmd, 0, True)
