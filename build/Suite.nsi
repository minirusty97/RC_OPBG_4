Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WordFunc.nsh"
!include "x64.nsh"
!ifndef APP_VERSION
  !error "APP_VERSION is required"
!endif
!ifndef PACKAGE_ROOT
  !error "PACKAGE_ROOT is required"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE is required"
!endif
!define PRODUCT "OPBG IT Suite"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\OPBGITSuite"
!define MARKER "OPBGITSuite-56bc1182-02a3-4b1a-9d4a-99d44231c26b"
Name "${PRODUCT}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\OPBGITSuite"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=1040 "ProductName" "${PRODUCT}"
VIAddVersionKey /LANG=1040 "FileDescription" "Installazione OPBG IT Suite"
VIAddVersionKey /LANG=1040 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1040 "LegalCopyright" "OPBG IT Suite contributors"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\OPBGITSuite.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Apri OPBG IT Suite"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Italian"

!macro CHECK_RUNNING PREFIX
Function ${PREFIX}CheckRunning
  System::Call 'kernel32::OpenEventW(i 0x00100000, i 0, w "Local\OPBGITSuite.Running") p.r0'
  ${If} $0 != 0
    System::Call 'kernel32::CloseHandle(p r0)'
    IfSilent +2
    MessageBox MB_OK|MB_ICONEXCLAMATION "Chiudere OPBG IT Suite e tutti i suoi moduli prima di continuare."
    SetErrorLevel 2
    Abort
  ${EndIf}
FunctionEnd
!macroend
!insertmacro CHECK_RUNNING ""
!insertmacro CHECK_RUNNING "un."

Function .onInit
  SetShellVarContext current
  SetRegView 64
  ${IfNot} ${RunningX64}
    IfSilent +2
    MessageBox MB_OK|MB_ICONSTOP "OPBG IT Suite richiede Windows a 64 bit."
    SetErrorLevel 2
    Abort
  ${EndIf}
  Call CheckRunning
  ReadRegStr $0 HKCU "${UNINSTALL_KEY}" "DisplayVersion"
  ${If} $0 != ""
    ${VersionCompare} $0 "${APP_VERSION}" $1
    ${If} $1 == 1
      IfSilent +2
      MessageBox MB_OK|MB_ICONEXCLAMATION "È già installata una versione più recente di OPBG IT Suite."
      SetErrorLevel 2
      Abort
    ${EndIf}
  ${EndIf}
FunctionEnd

Section "Installa"
  Call CheckRunning
  IfFileExists "$INSTDIR\app\*.*" 0 directory_ready
    IfFileExists "$INSTDIR\suite-install.marker" directory_ready 0
    IfSilent +2
    MessageBox MB_OK|MB_ICONSTOP "La cartella contiene file di un'altra applicazione. Scegliere un'altra cartella."
    SetErrorLevel 2
    Abort
  directory_ready:
  ; Only the reserved application directory is replaced. User data lives
  ; under LocalAppData\OPBG\ITSuite and is never removed by setup.
  RMDir /r "$INSTDIR\app"
  SetOutPath "$INSTDIR"
  File /r "${PACKAGE_ROOT}\*.*"
  FileOpen $0 "$INSTDIR\suite-install.marker" w
  FileWrite $0 "${MARKER}"
  FileClose $0
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\OPBG IT Suite"
  CreateShortcut "$SMPROGRAMS\OPBG IT Suite\OPBG IT Suite.lnk" "$INSTDIR\OPBGITSuite.exe"
  CreateShortcut "$SMPROGRAMS\OPBG IT Suite\Disinstalla.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\OPBG IT Suite.lnk" "$INSTDIR\OPBGITSuite.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${PRODUCT}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "OPBG IT Suite"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\OPBGITSuite.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "https://github.com/minirusty97/RC_OPBG_4"
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
  Call un.CheckRunning
  ClearErrors
  FileOpen $0 "$INSTDIR\suite-install.marker" r
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
  Delete "$INSTDIR\OPBGITSuite.exe"
  Delete "$INSTDIR\suite-install.marker"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\OPBG IT Suite\OPBG IT Suite.lnk"
  Delete "$SMPROGRAMS\OPBG IT Suite\Disinstalla.lnk"
  RMDir "$SMPROGRAMS\OPBG IT Suite"
  Delete "$DESKTOP\OPBG IT Suite.lnk"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
SectionEnd
