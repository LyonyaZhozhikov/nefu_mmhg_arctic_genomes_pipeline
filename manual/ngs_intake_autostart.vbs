' Starts the NGS intake (ngs intake start) two minutes after Windows logon.
' install_ngs.sh copies this file into the Startup folder.
WScript.Sleep 120000
CreateObject("WScript.Shell").Run "wsl.exe -d Ubuntu-24.04 -u ngs -- bash -lc ""bash /home/ngs/raredisease-setup/scripts/ngs.sh intake start""", 0, False
