# Generate one narration WAV per scene with the installed Korean voice, then
# write timings.json (scene id -> audio seconds) for the deterministic renderer.
param(
  [string]$ScriptPath = "$PSScriptRoot\..\public\film\script.json",
  [string]$OutDir     = "$PSScriptRoot\narration",
  [string]$VoiceName  = "Microsoft Heami Desktop",
  [int]$Rate          = -1
)

Add-Type -AssemblyName System.Speech
$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$film = Get-Content -Raw -Encoding UTF8 $ScriptPath | ConvertFrom-Json
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$synth.SelectVoice($VoiceName)
$synth.Rate = $Rate

$timings = [ordered]@{}
foreach ($scene in $film.scenes) {
  $wav = Join-Path $OutDir "$($scene.id).wav"
  $synth.SetOutputToWaveFile($wav)
  $synth.Speak($scene.narration)
  $synth.SetOutputToNull()

  $reader = New-Object System.Media.SoundPlayer $wav
  $reader.Load()
  $bytes = [System.IO.File]::ReadAllBytes($wav)
  # parse the WAV fmt/data chunks rather than trusting a fixed 44-byte header
  $pos = 12; $byteRate = 0; $dataLen = 0
  while ($pos -lt $bytes.Length - 8) {
    $id = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, 4)
    $size = [BitConverter]::ToUInt32($bytes, $pos + 4)
    if ($id -eq "fmt ") { $byteRate = [BitConverter]::ToUInt32($bytes, $pos + 16) }
    if ($id -eq "data") { $dataLen = $size; break }
    $pos += 8 + $size + ($size % 2)
  }
  $seconds = if ($byteRate -gt 0) { [math]::Round($dataLen / $byteRate, 3) } else { 3.0 }
  $timings[$scene.id] = $seconds
  "{0,-12} {1,6:N2}s  {2}" -f $scene.id, $seconds, $scene.narration.Substring(0, [Math]::Min(46, $scene.narration.Length))
}
$synth.Dispose()

$total = ($timings.Values | Measure-Object -Sum).Sum
$holds = ($film.scenes | ForEach-Object { $_.hold } | Measure-Object -Sum).Sum
$timings | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $PSScriptRoot "..\public\film\timings.json")
"---"
"narration total {0:N1}s + holds {1:N1}s = film {2:N1}s" -f $total, $holds, ($total + $holds)
