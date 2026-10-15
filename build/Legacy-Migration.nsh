; Names of released installations: used only for discovery and cleanup.
!define LEGACY_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\OPBGITSuite"
!define LEGACY_MARKER "OPBGITSuite-56bc1182-02a3-4b1a-9d4a-99d44231c26b"
Var LegacyInstallDir

!macro CHECK_LEGACY_RUNNING
  System::Call 'kernel32::OpenEventW(i 0x00100000, i 0, w "Local\OPBGITSuite.Running") p.r0'
  ${If} $0 != 0
    System::Call 'kernel32::CloseHandle(p r0)'
    IfSilent +2
    MessageBox MB_OK|MB_ICONEXCLAMATION "Chiudere la versione precedente e tutti i moduli prima di continuare."
    SetErrorLevel 2
    Abort
  ${EndIf}
!macroend

Function FindLegacyInstall
  ReadRegStr $LegacyInstallDir HKCU "${LEGACY_KEY}" "InstallLocation"
  ${If} $LegacyInstallDir == ""
    Return
  ${EndIf}
  ReadRegStr $0 HKCU "${LEGACY_KEY}" "DisplayVersion"
  ${VersionCompare} $0 "${APP_VERSION}" $1
  ${If} $1 == 1
    IfSilent +2
    MessageBox MB_OK|MB_ICONSTOP "È già installata una versione più recente."
    SetErrorLevel 2
    Abort
  ${EndIf}
  ClearErrors
  FileOpen $0 "$LegacyInstallDir\suite-install.marker" r
  IfErrors legacy_invalid
  FileRead $0 $1
  FileClose $0
  StrCmp $1 "${LEGACY_MARKER}" legacy_valid legacy_invalid
  legacy_invalid:
    IfSilent +2
    MessageBox MB_OK|MB_ICONSTOP "Impossibile riconoscere l'installazione precedente. Nessun file precedente è stato rimosso."
    SetErrorLevel 2
    Abort
  legacy_valid:
FunctionEnd

Function CheckLegacyLocation
  ${If} $LegacyInstallDir == ""
    Return
  ${EndIf}
  ${If} $LegacyInstallDir == $INSTDIR
    Return
  ${EndIf}
  ; A new install must not be nested inside an old payload, or vice versa.
  System::Call 'shlwapi::PathIsPrefixW(w "$LegacyInstallDir", w "$INSTDIR") i.r0'
  ${If} $0 == 0
    System::Call 'shlwapi::PathIsPrefixW(w "$INSTDIR", w "$LegacyInstallDir") i.r0'
  ${EndIf}
  ${If} $0 != 0
    IfSilent +2
    MessageBox MB_OK|MB_ICONSTOP "Scegliere una cartella separata dall'installazione precedente."
    SetErrorLevel 2
    Abort
  ${EndIf}
FunctionEnd

Function RemoveLegacyInstall
  ${If} $LegacyInstallDir != ""
    ${If} $LegacyInstallDir != $INSTDIR
      ; Only the payload owned by the verified legacy marker is removed.
      RMDir /r "$LegacyInstallDir\app"
      Delete "$LegacyInstallDir\AssistenteIT.exe"
      Delete "$LegacyInstallDir\Uninstall.exe"
    ${EndIf}
    Delete "$LegacyInstallDir\OPBGITSuite.exe"
    Delete "$LegacyInstallDir\suite-install.marker"
    ${If} $LegacyInstallDir != $INSTDIR
      RMDir "$LegacyInstallDir"
    ${EndIf}
    DeleteRegKey HKCU "${LEGACY_KEY}"
  ${EndIf}
  Delete "$SMPROGRAMS\OPBG IT Suite\OPBG IT Suite.lnk"
  Delete "$SMPROGRAMS\OPBG IT Suite\Disinstalla.lnk"
  RMDir "$SMPROGRAMS\OPBG IT Suite"
  Delete "$DESKTOP\OPBG IT Suite.lnk"
FunctionEnd
