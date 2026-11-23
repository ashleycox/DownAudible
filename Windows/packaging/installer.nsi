Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "nsDialogs.nsh"
!include "x64.nsh"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\DownAudible"
RequestExecutionLevel user
Name "DownAudible"
InstallDir "$LOCALAPPDATA\Programs\DownAudible"
; DisplayIcon is also available in installations made before the wizard.
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "DisplayIcon"
OutFile "${OUTPUT}"
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
SetCompressor lzma
SetCompressorDictSize 16
SetDateSave off
VIProductVersion "${VERSION}.${BUILD}"
VIAddVersionKey "ProductName" "DownAudible"
VIAddVersionKey "LegalCopyright" "Copyright © 2026 Ashley Cox"
VIAddVersionKey "FileDescription" "DownAudible installer (${ARCH})"
VIAddVersionKey "FileVersion" "${VERSION}.${BUILD}"
VIAddVersionKey "ProductVersion" "${VERSION}"

Var InstallParent
Var StagedInstall
Var PreviousInstall
Var SetupMutex
Var RegisteredInstall
Var DirectoryProblem
Var DesktopShortcut
Var DesktopCheckbox
Var OwnedDesktopLink

!define MUI_WELCOMEPAGE_TITLE "Install DownAudible"
!define MUI_WELCOMEPAGE_TEXT "This wizard installs DownAudible for your Windows account.$\r$\n$\r$\nChoose Next to review the installation folder and shortcut options."
!insertmacro MUI_PAGE_WELCOME
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE ConfirmInstallDirectory
!insertmacro MUI_PAGE_DIRECTORY
Page custom DesktopOptionsPage DesktopOptionsLeave
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\DownAudible.exe"
!define MUI_FINISHPAGE_RUN_TEXT "&Launch DownAudible"
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Open DownAudible &Help"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION OpenOfflineHelp
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_FINISHPAGE_LINK "DownAudible on GitHub"
!define MUI_FINISHPAGE_LINK_LOCATION "https://github.com/ashleycox/DownAudible"
!define MUI_FINISHPAGE_NOREBOOTSUPPORT
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

!macro TakeSetupLock
    System::Call 'kernel32::CreateMutexW(p 0, i 0, w "Local\DownAudibleSetup") p.r0 ?e'
    StrCpy $SetupMutex $0
    Pop $1
    StrCmp $SetupMutex 0 setup_busy
    IntCmp $1 183 setup_busy setup_ready setup_ready
    setup_busy:
        MessageBox MB_OK|MB_ICONEXCLAMATION "Another DownAudible installer or uninstaller is running." /SD IDOK
        SetErrorLevel 1
        Abort
    setup_ready:
!macroend

Function .onInit
    ${GetNativeMachineArchitecture} $0
    IntCmp $0 43620 architecture_ok
    !if "${ARCH}" == "x64"
        IntCmp $0 34404 architecture_ok
    !endif
        MessageBox MB_OK|MB_ICONEXCLAMATION "This DownAudible installer is for Windows ${ARCH}. Choose the installer that matches your computer." /SD IDOK
        SetErrorLevel 1
        Abort
    architecture_ok:
    !insertmacro TakeSetupLock
    SetShellVarContext current
    ReadRegStr $0 HKCU "${UNINSTALL_KEY}" "DisplayIcon"
    ${GetParent} "$0" $RegisteredInstall
    ${If} $RegisteredInstall != ""
    ${AndIf} ${FileExists} "$RegisteredInstall\DownAudible.exe"
    ${AndIf} ${FileExists} "$RegisteredInstall\Uninstall.exe"
        GetFullPathName $RegisteredInstall "$RegisteredInstall"
    ${Else}
        StrCpy $RegisteredInstall ""
    ${EndIf}
    ReadRegDWORD $DesktopShortcut HKCU "${UNINSTALL_KEY}" "DesktopShortcut"
    ${If} $DesktopShortcut != ${BST_CHECKED}
        StrCpy $DesktopShortcut ${BST_UNCHECKED}
    ${EndIf}
    ReadRegStr $OwnedDesktopLink HKCU "${UNINSTALL_KEY}" "DesktopShortcutPath"
FunctionEnd

Function un.onInit
    !insertmacro TakeSetupLock
    SetShellVarContext current
    ReadRegStr $0 HKCU "${UNINSTALL_KEY}" "DisplayIcon"
    ${GetParent} "$0" $0
    ${If} $0 != ""
        GetFullPathName $0 "$0"
        GetFullPathName $INSTDIR "$INSTDIR"
    ${EndIf}
    ${If} $0 == ""
    ${OrIf} $0 != $INSTDIR
        MessageBox MB_OK|MB_ICONEXCLAMATION "Open the DownAudible uninstaller from Windows Settings." /SD IDOK
        SetErrorLevel 1
        Abort
    ${EndIf}
    ReadRegStr $OwnedDesktopLink HKCU "${UNINSTALL_KEY}" "DesktopShortcutPath"
FunctionEnd

Function ValidateInstallDirectory
    StrCpy $DirectoryProblem "Choose an absolute path to an installation folder."
    ${GetRoot} "$INSTDIR" $0
    StrLen $1 "$0"
    StrCpy $2 "$INSTDIR" 1 $1
    ${If} $0 == ""
    ${OrIf} $2 != "\"
        Return
    ${EndIf}
    StrCpy $2 "$INSTDIR" 4
    ${If} $2 == "\\?\"
    ${OrIf} $2 == "\\.\"
        Return
    ${EndIf}
    ; The Win32 function normalizes paths before their directories exist.
    System::Call 'kernel32::GetFullPathNameW(w "$INSTDIR", i ${NSIS_MAX_STRLEN}, w .r0, p 0) i.r1'
    ${If} $1 = 0
    ${OrIf} $1 >= ${NSIS_MAX_STRLEN}
        Return
    ${EndIf}
    StrCpy $INSTDIR "$0"
    System::Call 'kernel32::GetFullPathNameW(w "$INSTDIR\..", i ${NSIS_MAX_STRLEN}, w .r0, p 0) i.r1'
    ${If} $1 = 0
    ${OrIf} $1 >= ${NSIS_MAX_STRLEN}
    ${OrIf} $INSTDIR == $0
        Return
    ${EndIf}
    StrCpy $InstallParent "$0"
    ${If} $RegisteredInstall != ""
    ${AndIf} $RegisteredInstall != $INSTDIR
        StrCpy $DirectoryProblem "Updates use the current folder at $RegisteredInstall. To move DownAudible, uninstall it and run Setup again."
        Return
    ${EndIf}
    StrCpy $0 "$LOCALAPPDATA\DownAudible\"
    StrLen $1 "$0"
    StrCpy $2 "$INSTDIR\" $1
    ${If} $0 == $2
        StrCpy $DirectoryProblem "Choose a folder outside DownAudible’s app data folder."
        Return
    ${EndIf}
    StrCpy $DirectoryProblem ""
    System::Call 'kernel32::GetFileAttributesW(w "$INSTDIR") i.r0'
    ${If} $0 = -1
        Return
    ${EndIf}
    IntOp $0 $0 & 0x410
    ${If} $0 <> 0x10
        StrCpy $DirectoryProblem "Choose a folder. Setup cannot use an existing file or a folder link."
        Return
    ${EndIf}
    ${If} $RegisteredInstall == $INSTDIR
        Return
    ${EndIf}
    ClearErrors
    FindFirst $0 $1 "$INSTDIR\*"
    ${While} $1 != ""
        ${If} $1 != "."
        ${AndIf} $1 != ".."
            StrCpy $DirectoryProblem "Choose a new or empty folder for DownAudible."
            ${Break}
        ${EndIf}
        FindNext $0 $1
    ${EndWhile}
    FindClose $0
FunctionEnd

Function ConfirmInstallDirectory
    Call ValidateInstallDirectory
    ${If} $DirectoryProblem != ""
        MessageBox MB_OK|MB_ICONEXCLAMATION "$DirectoryProblem"
        Abort
    ${EndIf}
FunctionEnd

Function DesktopOptionsPage
    !insertmacro MUI_HEADER_TEXT "Shortcuts" "Choose whether to add a desktop shortcut."
    nsDialogs::Create 1018
    Pop $0
    ${If} $0 == error
        Abort
    ${EndIf}
    ${NSD_CreateLabel} 0 0 100% 18u "Setup adds DownAudible to the Start menu."
    Pop $0
    ${NSD_CreateCheckbox} 0 22u 100% 14u "&Create a desktop shortcut"
    Pop $DesktopCheckbox
    ${NSD_SetState} $DesktopCheckbox $DesktopShortcut
    nsDialogs::Show
FunctionEnd

Function DesktopOptionsLeave
    ${NSD_GetState} $DesktopCheckbox $DesktopShortcut
FunctionEnd

Function OpenOfflineHelp
    ExecShell "open" "$INSTDIR\resources\Help\README.html"
FunctionEnd

; The persisted path identifies the shortcut Setup created. Confirm it still
; points to this installation before removing it, including during uninstall.
!macro DefineRemoveOwnedDesktopShortcut Prefix
Function ${Prefix}RemoveOwnedDesktopShortcut
    ${If} $OwnedDesktopLink == ""
    ${OrIfNot} ${FileExists} "$OwnedDesktopLink"
        Return
    ${EndIf}
    ; CLSID_ShellLink and IID_IShellLinkW, followed by IID_IPersistFile.
    System::Call 'ole32::CoCreateInstance(g "{00021401-0000-0000-C000-000000000046}", p 0, i 1, g "{000214F9-0000-0000-C000-000000000046}", *p .r1) i.r0'
    ${If} $0 != 0
        Return
    ${EndIf}
    System::Call '$1->0(g "{0000010b-0000-0000-C000-000000000046}", *p .r2) i.r0'
    ${If} $0 == 0
        ; IPersistFile::Load, IShellLinkW::GetPath and IUnknown::Release.
        System::Call '$2->5(w "$OwnedDesktopLink", i 0) i.r0'
        ${If} $0 == 0
            System::Call '$1->3(w .r3, i ${NSIS_MAX_STRLEN}, p 0, i 4) i.r0'
            ${If} $0 == 0
            ${AndIf} $3 == "$INSTDIR\DownAudible.exe"
                Delete "$OwnedDesktopLink"
            ${EndIf}
        ${EndIf}
        System::Call '$2->2()'
    ${EndIf}
    System::Call '$1->2()'
FunctionEnd
!macroend

!insertmacro DefineRemoveOwnedDesktopShortcut ""
!insertmacro DefineRemoveOwnedDesktopShortcut "un."

Function ConfigureDesktopShortcut
    ${If} $DesktopShortcut == ${BST_CHECKED}
        ${IfNot} ${FileExists} "$DESKTOP\DownAudible.lnk"
            ClearErrors
            CreateShortcut "$DESKTOP\DownAudible.lnk" "$INSTDIR\DownAudible.exe"
            ${IfNot} ${Errors}
                ${If} $OwnedDesktopLink != "$DESKTOP\DownAudible.lnk"
                    Call RemoveOwnedDesktopShortcut
                ${EndIf}
                WriteRegStr HKCU "${UNINSTALL_KEY}" "DesktopShortcutPath" "$DESKTOP\DownAudible.lnk"
            ${Else}
                DetailPrint "The desktop shortcut could not be created. DownAudible is available from the Start menu."
            ${EndIf}
        ${ElseIf} $OwnedDesktopLink != "$DESKTOP\DownAudible.lnk"
            DetailPrint "A desktop shortcut named DownAudible already exists. Setup kept it."
        ${EndIf}
    ${Else}
        Call RemoveOwnedDesktopShortcut
        ${IfNot} ${FileExists} "$OwnedDesktopLink"
            DeleteRegValue HKCU "${UNINSTALL_KEY}" "DesktopShortcutPath"
        ${EndIf}
    ${EndIf}
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "DesktopShortcut" $DesktopShortcut
FunctionEnd

!macro RemoveProgramFiles Root
    Delete "${Root}\DownAudible.exe"
    RMDir /r "${Root}\python"
    RMDir /r "${Root}\resources"
    Delete "${Root}\LICENSE.txt"
    Delete "${Root}\Uninstall.exe"
!macroend

Function RestoreOtherFiles
    FindFirst $0 $1 "$PreviousInstall\*"
    ${While} $1 != ""
        ${If} $1 != "."
        ${AndIf} $1 != ".."
        ${AndIfNot} ${FileExists} "$INSTDIR\$1"
            Rename "$PreviousInstall\$1" "$INSTDIR\$1"
        ${EndIf}
        FindNext $0 $1
    ${EndWhile}
    FindClose $0
FunctionEnd

Section "DownAudible"
    SetShellVarContext current
    Call ValidateInstallDirectory
    ${If} $DirectoryProblem != ""
        MessageBox MB_OK|MB_ICONEXCLAMATION "$DirectoryProblem" /SD IDOK
        SetErrorLevel 1
        Abort
    ${EndIf}
    ClearErrors
    CreateDirectory "$InstallParent"
    GetTempFileName $StagedInstall "$InstallParent"
    IfErrors install_failed
    Delete "$StagedInstall"
    SetOutPath "$StagedInstall"
    File /r "${BUNDLE}\*.*"
    IfErrors discard_staged
    WriteUninstaller "$StagedInstall\Uninstall.exe"
    IfErrors discard_staged
    SetOutPath "$InstallParent"
    StrCpy $PreviousInstall ""
    StrCmp $INSTDIR $RegisteredInstall 0 publish_new
        IfFileExists "$INSTDIR\.running" 0 prepare_backup
        Delete "$INSTDIR\.running"
        IfErrors discard_staged
    prepare_backup:
        GetTempFileName $PreviousInstall "$InstallParent"
        IfErrors discard_staged
        Delete "$PreviousInstall"
        Rename "$INSTDIR" "$PreviousInstall"
        IfErrors discard_staged
        Goto publish
    publish_new:
        ; Rename cannot replace an existing directory, including an empty one.
        ; A nonempty folder is preserved if anything arrived after validation.
        RMDir "$INSTDIR"
        ClearErrors
    publish:
        Rename "$StagedInstall" "$INSTDIR"
        IfErrors restore_previous
        StrCmp $PreviousInstall "" register
        !insertmacro RemoveProgramFiles "$PreviousInstall"
        Call RestoreOtherFiles
        ClearErrors
        RMDir "$PreviousInstall"
        IfErrors 0 register
        DetailPrint "Other files were kept in $PreviousInstall."
    register:
        SetOutPath "$INSTDIR"
        CreateShortcut "$SMPROGRAMS\DownAudible.lnk" "$INSTDIR\DownAudible.exe"
        WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "DownAudible"
        WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
        WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
        WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
        WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\DownAudible.exe"
        WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
        WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
        Call ConfigureDesktopShortcut
        Goto install_done
    restore_previous:
        StrCmp $PreviousInstall "" discard_staged
        ClearErrors
        Rename "$PreviousInstall" "$INSTDIR"
        IfErrors restore_failed
    discard_staged:
        SetOutPath "$InstallParent"
        RMDir /r "$StagedInstall"
    install_failed:
        MessageBox MB_OK|MB_ICONEXCLAMATION "DownAudible could not be installed. Quit DownAudible and try again." /SD IDOK
        SetErrorLevel 1
        Abort
    restore_failed:
        MessageBox MB_OK|MB_ICONEXCLAMATION "DownAudible could not be installed. The previous installation is in $PreviousInstall." /SD IDOK
        SetErrorLevel 1
        Abort
    install_done:
SectionEnd

Section "Uninstall"
    SetShellVarContext current
    SetOutPath "$TEMP"
    ClearErrors
    IfFileExists "$INSTDIR\.running" 0 uninstall_files
    Delete "$INSTDIR\.running"
    IfErrors uninstall_running
    uninstall_files:
    !insertmacro RemoveProgramFiles "$INSTDIR"
    IfErrors uninstall_running
    Delete "$SMPROGRAMS\DownAudible.lnk"
    Call un.RemoveOwnedDesktopShortcut
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
    RMDir "$INSTDIR"
    Goto uninstall_done
    uninstall_running:
        MessageBox MB_OK|MB_ICONEXCLAMATION "Quit DownAudible and run the uninstaller again." /SD IDOK
        SetErrorLevel 1
        Abort
    uninstall_done:
SectionEnd
