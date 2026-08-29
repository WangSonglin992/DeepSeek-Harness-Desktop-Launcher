Option Explicit

Dim shell, fileSystem, scriptDirectory, powershellPath, launcherPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
launcherPath = fileSystem.BuildPath(scriptDirectory, "Launch-DeepSeek-Harness.ps1")
command = Chr(34) & powershellPath & Chr(34) & _
    " -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & launcherPath & Chr(34)

shell.Run command, 0, False
