[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$BraveDir,
 [string]$Publisher='CN=Chaython',
 [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version='1.0.0.0',
 [string]$PfxPath,
 [string]$PfxPassword
)
$ErrorActionPreference='Stop'
$src=(Resolve-Path -LiteralPath $BraveDir).ProviderPath
$braves=@(Get-ChildItem -LiteralPath $src -Filter 'brave.exe' -File -Recurse)
if($braves.Count -ne 1){throw 'BraveDir must contain exactly one brave.exe.'}
if(-not (Get-Command cargo -ErrorAction SilentlyContinue)){throw 'Install Rust and cargo first.'}
$sdkRoot=Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Windows Kits\10\bin'
$sdks=@(Get-ChildItem -LiteralPath $sdkRoot -Directory | Sort-Object Name -Descending)
$makeAppx=$null
$signTool=$null
foreach($sdk in $sdks){
 $candidate=Join-Path $sdk.FullName 'x64\makeappx.exe'
 if(Test-Path -LiteralPath $candidate){
  $makeAppx=$candidate
  $signTool=Join-Path $sdk.FullName 'x64\signtool.exe'
  break
 }
}
if(-not $makeAppx){throw 'Windows SDK makeappx.exe is required.'}
Push-Location $PSScriptRoot
try {
 & cargo build --release --target x86_64-pc-windows-msvc
 if($LASTEXITCODE -ne 0){throw 'Cargo build failed.'}
} finally {Pop-Location}
$stage=Join-Path $PSScriptRoot '.stage'
$out=Join-Path $PSScriptRoot 'out'
if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path $out -Force | Out-Null
$launcher=Join-Path $PSScriptRoot 'target\x86_64-pc-windows-msvc\release\BravePortableMsix.exe'
Copy-Item -LiteralPath $launcher -Destination $stage -ErrorAction Stop
Copy-Item -LiteralPath $src -Destination (Join-Path $stage 'App') -Recurse -Force
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'AppxManifest.xml.in') -Raw
$manifest = $manifest.Replace('__PUBLISHER__', [System.Security.SecurityElement]::Escape($Publisher))
$manifest = $manifest.Replace('__VERSION__', $Version)
[IO.File]::WriteAllText((Join-Path $stage 'AppxManifest.xml'),$manifest,(New-Object Text.UTF8Encoding($false)))
$assets=Join-Path $stage 'Assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
Add-Type -AssemblyName System.Drawing
foreach($entry in @(@('StoreLogo.png',50),@('Square44x44Logo.png',44),@('Square150x150Logo.png',150))){
 $size=[int]$entry[1]
 $bmp=New-Object System.Drawing.Bitmap($size,$size)
 try {
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  try {
   $g.Clear([System.Drawing.Color]::FromArgb(30,41,59))
   $font=New-Object System.Drawing.Font('Arial',[single]($size*0.5),[System.Drawing.FontStyle]::Bold)
   $brush=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
   try {$g.DrawString('B',$font,$brush,[single]($size*0.1),[single]($size*0.1))}
   finally {$brush.Dispose();$font.Dispose()}
  } finally {$g.Dispose()}
  $bmp.Save((Join-Path $assets $entry[0]),[System.Drawing.Imaging.ImageFormat]::Png)
 } finally {$bmp.Dispose()}
}
$package=Join-Path $out ('BravePortableMSIX_{0}_x64.msix' -f $Version)
if(Test-Path -LiteralPath $package){Remove-Item -LiteralPath $package -Force}
& $makeAppx pack /d $stage /p $package /o
if($LASTEXITCODE -ne 0){throw 'MakeAppx failed.'}
if($PfxPath){
 if(-not (Test-Path -LiteralPath $signTool)){throw 'SignTool not found.'}
 $argsList=@('sign','/fd','SHA256','/f',(Resolve-Path -LiteralPath $PfxPath).ProviderPath)
 if($PSBoundParameters.ContainsKey('PfxPassword')){$argsList+=@('/p',$PfxPassword)}
 $argsList+=$package
 & $signTool @argsList
 if($LASTEXITCODE -ne 0){throw 'Signing failed.'}
}else{Write-Warning 'Unsigned MSIX: sign with a trusted certificate before installation.'}
Write-Host "Created $package"
