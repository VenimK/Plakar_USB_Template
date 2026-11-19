Plakar Technician USB Template (Cross-Platform)

- Place plakar.exe (Windows) and plakar (macOS/Linux) in the root
- Use menu.ps1 on Windows or menu.sh on macOS/Linux
- plakar_repo will be used/created automatically inside this USB folder
- Logs are stored in the logs/ folder; USMT scratch space is in work/
- USMT (scanstate/loadstate) is Windows-only and runs through menu.ps1 or
  webserver.ps1; the XMLs include the optional migmodern.xml rules
- Optional .plakar_key stores your repository passphrase
  (edit this file and replace 'CHANGE_THIS_PASSPHRASE' with your real passphrase)
