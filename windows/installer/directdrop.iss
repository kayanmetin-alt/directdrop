; DirectDrop Windows installer — build with Inno Setup 6 after `flutter build windows --release`

#define MyAppName "DirectDrop"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "DirectDrop"
#define MyAppExeName "directdrop.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"
#define AppIcon "..\runner\resources\app_icon.ico"

[Setup]
AppId={{8F4E2A1B-3C5D-4E6F-9A0B-1C2D3E4F5A6B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=..\..\dist\windows
OutputBaseFilename=DirectDrop-Setup-{#MyAppVersion}
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
DisableProgramGroupPage=no
DisableWelcomePage=no

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
function VCRedistInstalled: Boolean;
var
  Version: String;
begin
  Result :=
    RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Version', Version) or
    RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Version', Version);
end;

function InitializeSetup: Boolean;
begin
  Result := True;
  if not VCRedistInstalled then
    MsgBox(
      'DirectDrop, Microsoft Visual C++ 2015-2022 Redistributable (x64) gerektirir.' + #13#10 +
      'Kurulumdan sonra çalışmazsa şu paketi yükleyin:' + #13#10 +
      'https://aka.ms/vs/17/release/vc_redist.x64.exe',
      mbInformation, MB_OK);
end;
