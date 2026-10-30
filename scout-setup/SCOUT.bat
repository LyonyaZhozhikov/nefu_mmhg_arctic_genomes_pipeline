@echo off
rem Open Scout. Usage: SCOUT.bat                 open http://localhost:8000
rem                    SCOUT.bat load RUN        load D:\data_annotated\RUN into Scout
rem                    SCOUT.bat research RUN    also load the full research variant set
chcp 65001 >nul
tasklist /fi "imagename eq wscript.exe" | find /i "wscript.exe" >nul || start "" wscript.exe "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\scout_keepalive.vbs"
if "%~1"=="load" (
  wsl.exe -d scout -u root bash /mnt/c/NGS_pipeline/Claude_folder/scout-setup/scout_load.sh "%~2"
  pause
  exit /b
)
if "%~1"=="research" (
  wsl.exe -d scout -u root bash /mnt/c/NGS_pipeline/Claude_folder/scout-setup/scout_load.sh research "%~2"
  pause
  exit /b
)
start "" http://localhost:8000
