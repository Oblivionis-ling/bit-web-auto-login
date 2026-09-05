Option Explicit

Dim shell, fileSystem, scriptDirectory, command, result
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & scriptDirectory & "\Manage.ps1""" & " -HideConsole"
result = shell.Run(command, 1, False)
If result <> 0 Then
    MsgBox "Could not start BIT-Web Auto Login Manager.", vbCritical, "BIT-Web Auto Login Manager"
End If
