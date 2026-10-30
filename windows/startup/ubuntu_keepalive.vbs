CreateObject("WScript.Shell").Run "wsl.exe -d Ubuntu-24.04 -u ngs -- bash -c ""exec -a wsl_keepalive sleep infinity""", 0, False
