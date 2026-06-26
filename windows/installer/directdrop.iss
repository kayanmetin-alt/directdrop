; DirectDrop Windows installer — build with Inno Setup 6 after `flutter build windows --release`
; Sürüm: scripts/write_installer_version.ps1 → version.iss (CI ve yerel build önce bunu üretir)

#include "version.iss"
#define MyAppName "DirectDrop"
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
; WebRTC P2P icin Windows Guvenlik Duvari kurali eklenir; bu islem yonetici
; yetkisi gerektirir. Yetki yoksa kullanici kurulumu da kabul edilir (kural
; o durumda atlanir, uygulama ilk acilista guvenlik duvari istemi gosterir).
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
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
Source: "redist\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: VCRedistNeedsInstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Visual C++ calisma zamani kuruluyor..."; Check: VCRedistNeedsInstall; Flags: waituntilterminated
; WebRTC eslestirme/transfer trafigi icin guvenlik duvari istisnalari (gelen+giden, TCP+UDP, tum profiller).
; Onceki kurulumdan kalan ayni isimli kurallari once temizle (cift kayit olusmasin).
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""DirectDrop"""; Flags: runhidden; Check: IsAdminInstallMode
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""DirectDrop"" dir=in action=allow program=""{app}\{#MyAppExeName}"" enable=yes profile=any protocol=tcp"; StatusMsg: "Guvenlik duvari kurali ekleniyor..."; Flags: runhidden; Check: IsAdminInstallMode
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""DirectDrop"" dir=in action=allow program=""{app}\{#MyAppExeName}"" enable=yes profile=any protocol=udp"; Flags: runhidden; Check: IsAdminInstallMode
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""DirectDrop"" dir=out action=allow program=""{app}\{#MyAppExeName}"" enable=yes profile=any protocol=tcp"; Flags: runhidden; Check: IsAdminInstallMode
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""DirectDrop"" dir=out action=allow program=""{app}\{#MyAppExeName}"" enable=yes profile=any protocol=udp"; Flags: runhidden; Check: IsAdminInstallMode
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""DirectDrop"""; Flags: runhidden; RunOnceId: "DelDirectDropFwRule"; Check: IsAdminInstallMode

[Code]
function VCRedistNeedsInstall: Boolean;
var
  Version: String;
begin
  Result := not (
    RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Version', Version) or
    RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Version', Version)
  );
end;
