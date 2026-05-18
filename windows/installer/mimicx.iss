; ===========================================================================
; MimicX Windows installer (Inno Setup 6)
; ---------------------------------------------------------------------------
; ローカルビルド:
;   "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" /DMyAppVersion=1.0.11 ^
;     windows\installer\mimicx.iss
; ※ build\windows\x64\runner\Release が事前に出来ていること
;   (flutter build windows --release)。
;
; CI:
;   .github/workflows/release-build.yml の Windows ジョブで pubspec の
;   version を /DMyAppVersion=... として渡して ISCC を実行する。
;
; 注意:
;   - AppId は一度決めたら変更しない (アップグレード判定 / アン
;     インストール識別が壊れる)。
;   - 無署名インストーラなので SmartScreen 警告は出る。回避は
;     EV 証明書 or Azure Trusted Signing が必要。
; ===========================================================================

#define MyAppName       "MimicX"
#define MyAppPublisher  "Kunihiko Ohnaka"
#define MyAppURL        "https://github.com/kunichiko/MimicX-app"
#define MyAppExeName    "mimicx.exe"
; .iss の置き場所からの相対パス (windows\installer → リポジトリルート → build\...)
#define BuildDir        "..\..\build\windows\x64\runner\Release"
#define IconFile        "..\runner\resources\app_icon.ico"

; CI から /DMyAppVersion=1.2.3 で渡す。ローカル単発ビルド用に既定値も置く。
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{EA867AE7-8788-4E06-84C4-9638CA862D06}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
VersionInfoVersion={#MyAppVersion}
; 管理者権限を要求せず Per-user / Per-machine をユーザーに選ばせる。
; admin の場合 {autopf} = Program Files、非 admin の場合 LocalAppData\Programs。
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=.
OutputBaseFilename=MimicX_windows-setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#MyAppExeName}
; 既存の mimicx.exe が起動中なら自動的に閉じてから上書きインストール。
CloseApplications=force
RestartApplications=no
; インストールに必要なディスクサイズ表示の精度向上。
DiskSpanning=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Flutter ビルド出力一式をそのまま {app} に配置する。data\ 以下のアセット、
; 各種 dll (flutter_windows.dll, プラグイン dll) を含む。
Source: "{#BuildDir}\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; \
    Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; \
    Description: "{cm:LaunchProgram,{#MyAppName}}"; \
    Flags: nowait postinstall skipifsilent
