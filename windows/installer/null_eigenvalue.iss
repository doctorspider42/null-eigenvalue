; The Windows installer.
;
;   ISCC /DAppVersion=0.1.42 windows\installer\null_eigenvalue.iss
;
; Two things here are load-bearing for the in-app updater and neither is the
; obvious default:
;
;   PrivilegesRequired=lowest        installs under the user's own profile, so
;                                    an update started from inside the app runs
;                                    without a UAC prompt - which it could not
;                                    answer anyway, having just closed itself.
;   AppId                            fixed forever. It is what tells Windows
;                                    that this is the same program as the one
;                                    already installed, and therefore an
;                                    upgrade in place rather than a second copy
;                                    in a second folder.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

#define AppName "Null Eigenvalue"
#define AppExe "null_eigenvalue.exe"
#define AppPublisher "Null Eigenvalue"
#define AppUrl "https://github.com/doctorspider42/null-eigenvalue"

[Setup]
AppId={{9E6C3F1B-2A4D-4C7E-9F3B-6D0A5E8C41B2}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVersion}

DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; There is one place this sensibly goes and the app is 30 MB. Asking where to
; put it is a page nobody reads.
DisableDirPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

OutputDir=.
OutputBaseFilename=NullEigenvalue-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; The wizard is three seconds of somebody's evening. Keep it dark, like the
; thing it is installing.
WizardSizePercent=100

; Shuts the app down if it is running and puts it back afterwards. The updater
; exits on its own before handing over, but an install started by hand from the
; downloaded .exe has no such courtesy.
CloseApplications=yes
RestartApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
; The whole Flutter bundle: the runner, the engine DLLs, nulleig.dll and the
; data directory. Recursed rather than listed, because the set of DLLs is
; Flutter's business and it changes between versions.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; No skipifsilent: a silent run is what the in-app updater does, and coming
; back to a closed app would read as the update having killed it.
Filename: "{app}\{#AppExe}"; Description: "Open {#AppName}"; Flags: nowait postinstall
