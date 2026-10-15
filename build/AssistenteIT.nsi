Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WordFunc.nsh"
!include "x64.nsh"
!include "FileFunc.nsh"
!ifndef APP_VERSION
  !error "APP_VERSION is required"
!endif
!ifndef PACKAGE_ROOT
  !error "PACKAGE_ROOT is required"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE is required"
!endif
!define PRODUCT "Assistente IT"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\AssistenteIT"
!define MARKER "AssistenteIT-56bc1182-02a3-4b1a-9d4a-99d44231c26b"
!include "${__FILEDIR__}\Legacy-Migration.nsh"
Name "${PRODUCT}"
OutFile "${OUTPUT_FILE}"
; An explicit /D is populated before .onInit; otherwise choose the 64-bit registry/default path.
InstallDir ""
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=1040 "ProductName" "${PRODUCT}"
VIAddVersionKey /LANG=1040 "FileDescription" "Installazione Assistente IT"
VIAddVersionKey /LANG=1040 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1040 "LegalCopyright" "Assistente IT contributors"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\AssistenteIT.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Apri Assistente IT"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Italian"

!macro CHECK_RUNNING PREFIX
Function ${PREFIX}CheckRunning
  System::Call 'kernel32::OpenEventW(i 0x00100000, i 0, w "Local\AssistenteIT.Running") p.r0'
  ${If} $0 != 0
    System::Call 'kernel32::CloseHandle(p r0)'
    IfSilent +2
    MessageBox MB_OK|MB_ICONEXCLAMATION "Chiudere Assistente IT e tutti i suoi moduli prima di continuare."
    SetErrorLevel 2
    Abort
  ${EndIf}
  !insertmacro CHECK_LEGACY_RUNNING
FunctionEnd
!macroend
!insertmacro CHECK_RUNNING ""
!insertmacro CHECK_RUNNING "un."

Function .onInit
  SetShellVarContext current
  SetRegView 64
  ${IfNot} ${RunningX64}
    IfSilent +2
    MessageBox MB_OK|MB_ICONSTOP "Assistente IT richiede Windows a 64 bit."
    SetErrorLevel 2
    Abort
  ${EndIf}
  Call CheckRunning
  ReadRegStr $0 HKCU "${UNINSTALL_KEY}" "DisplayVersion"
  ${If} $0 != ""
    ${VersionCompare} $0 "${APP_VERSION}" $1
    ${If} $1 == 1
      IfSilent +2
      MessageBox MB_OK|MB_ICONEXCLAMATION "È già installata una versione più recente di Assistente IT."
      SetErrorLevel 2
      Abort
    ${EndIf}
    ; Restore the registered 64-bit path unless /D selected another folder.
    ReadRegStr $1 HKCU "${UNINSTALL_KEY}" "InstallLocation"
    ${If} $INSTDIR == ""
      StrCpy $INSTDIR $1
    ${EndIf}
  ${EndIf}
  ${If} $INSTDIR == ""
    StrCpy $INSTDIR "$LOCALAPPDATA\Programs\AssistenteIT"
  ${EndIf}
  Call FindLegacyInstall
FunctionEnd

Section "Installa"
  Call CheckRunning
  Call CheckLegacyLocation
  IfFileExists "$INSTDIR\app\*.*" 0 directory_ready
    ClearErrors
    FileOpen $0 "$INSTDIR\assistente-it-install.marker" r
    IfErrors check_legacy_marker
    FileRead $0 $1
    FileClose $0
    StrCmp $1 "${MARKER}" directory_ready directory_invalid
    check_legacy_marker:
      StrCmp $INSTDIR $LegacyInstallDir directory_ready directory_invalid
    directory_invalid:
      IfSilent +2
      MessageBox MB_OK|MB_ICONSTOP "La cartella contiene file di un'altra applicazione. Scegliere un'altra cartella."
      SetErrorLevel 2
      Abort
  directory_ready:
  ; Config and tokens live under LocalAppData\AssistenteIT, outside app.
  RMDir /r "$INSTDIR\app"
  SetOutPath "$INSTDIR"
  ClearErrors
  File /r "${PACKAGE_ROOT}\*.*"
  IfErrors install_failed
  ; Move personal data before removing the verified previous installation.
  SetRegView 64
  ${DisableX64FSRedirection}
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\app\AssistenteIT\Import-UserData.ps1"'
  Pop $0
  Pop $1
  ${EnableX64FSRedirection}
  ${If} $0 != 0
    IfSilent +2
    MessageBox MB_OK|MB_ICONSTOP "Migrazione dei dati personali non completata. I dati precedenti sono conservati. Riprovare il setup."
    SetErrorLevel 2
    Abort
  ${EndIf}
  Call RemoveLegacyInstall
  FileOpen $0 "$INSTDIR\assistente-it-install.marker" w
  FileWrite $0 "${MARKER}"
  FileClose $0
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Assistente IT"
  CreateShortcut "$SMPROGRAMS\Assistente IT\Assistente IT.lnk" "$INSTDIR\AssistenteIT.exe"
  CreateShortcut "$SMPROGRAMS\Assistente IT\Disinstalla.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\Assistente IT.lnk" "$INSTDIR\AssistenteIT.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${PRODUCT}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Assistente IT"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\AssistenteIT.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "https://github.com/minirusty97/RC_OPBG_4"
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  Goto install_done
  install_failed:
    SetErrorLevel 2
    Abort
  install_done:
SectionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
  Call un.CheckRunning
  ClearErrors
  FileOpen $0 "$INSTDIR\assistente-it-install.marker" r
  IfErrors bad_marker
  FileRead $0 $1
  FileClose $0
  StrCmp $1 "${MARKER}" marker_ok bad_marker
  bad_marker:
    IfSilent +2
    MessageBox MB_OK|MB_ICONSTOP "Installazione non riconosciuta. Nessun file è stato rimosso."
    SetErrorLevel 2
    Abort
  marker_ok:
FunctionEnd

Section "Uninstall"
  Call un.CheckRunning
  RMDir /r "$INSTDIR\app"
  Delete "$INSTDIR\AssistenteIT.exe"
  Delete "$INSTDIR\assistente-it-install.marker"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Assistente IT\Assistente IT.lnk"
  Delete "$SMPROGRAMS\Assistente IT\Disinstalla.lnk"
  RMDir "$SMPROGRAMS\Assistente IT"
  Delete "$DESKTOP\Assistente IT.lnk"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
SectionEnd
