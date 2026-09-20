<#
.SYNOPSIS
  Install the agent pipeline for OpenCode v2 on Windows - globally, so that no code
  repository ever contains an agent, a skill, a config, a plan or a note.

.DESCRIPTION
  The agents and the config land in %USERPROFILE%\.config\opencode (that, not %APPDATA%,
  is where OpenCode looks on Windows - `opencode debug paths` prints it):

    agents\      the seven pipeline agents, plus the converted team agents (-TeamRepo)
    commands\    /ticket, /intake
    opencode.jsonc   ONLY if no opencode.json(c) exists yet. An existing config is never
                     touched; the script prints what to merge by hand instead.

  An installed agent or command that differs from the kit is backed up (as *.md.bak, so
  OpenCode cannot load the backup as a second agent) before it is replaced.

  The ticket workspaces - one folder per ticket, where you open OpenCode and where every
  file of the pipeline lives - go under -WorkspaceRoot (default: Documents\opencode).
  new-ticket.ps1 and TICKET.template.md are copied there. No code repository and no git
  setting is touched.

.EXAMPLE
  .\install.ps1 -BaseUrl http://llm.corp.example:8000/v1 -ModelId qwen3.8-27b -TeamRepo C:\repos\agent_and_skills
.EXAMPLE
  .\install.ps1                      # agents, commands and new-ticket.ps1 only; config left alone
.EXAMPLE
  .\install.ps1 -TeamRepo C:\repos\agent_and_skills -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$TeamRepo,
  [string]$BaseUrl,
  [string]$ModelId,
  [string]$ConfigDir = (Join-Path $env:USERPROFILE '.config\opencode'),
  # Where the ticket workspaces live. GetFolderPath, not $HOME\Documents: on a work machine
  # Documents is often redirected (OneDrive), and that is the folder you mean.
  [string]$WorkspaceRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'opencode'),
  # The web is open by default: agents look up documentation and errors like a developer
  # would. -NoWeb writes the four denies that really close it (webfetch, websearch, execute,
  # browser - `execute` can fetch() too, so denying webfetch alone locks nothing). Use it
  # when company policy or an offline network says so. Only affects a config written NOW.
  [switch]$NoWeb,
  # `opencode reload` restarts every location of the shared background service. MEASURED:
  # tool calls in flight in a running session are aborted ("Interaction cancelled because
  # the location shut down"). So it is opt-in: pass -Reload only when nothing is working.
  [switch]$Reload
)
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
# Windows PowerShell 5.1 puts a BOM in front of -Encoding utf8 output; write without one.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($TeamRepo) { $TeamRepo = (Resolve-Path -LiteralPath $TeamRepo).Path }

# Copy kit files into a config subfolder, backing up any target that differs.
function Install-Files([string]$fromDir, [string]$subdir) {
  $to = Join-Path $ConfigDir $subdir
  if (-not (Test-Path -LiteralPath $to)) { if ($PSCmdlet.ShouldProcess($to, 'create folder')) { New-Item -ItemType Directory -Force -Path $to | Out-Null } }
  foreach ($f in (Get-ChildItem -LiteralPath $fromDir -Filter *.md -File)) {
    $target = Join-Path $to $f.Name
    if (Test-Path -LiteralPath $target) {
      if ((Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) { Write-Host "same   $subdir\$($f.Name)"; continue }
      $bak = Join-Path $ConfigDir "backup-$Stamp"
      if ($PSCmdlet.ShouldProcess($target, "back up to $bak and replace")) {
        New-Item -ItemType Directory -Force -Path $bak | Out-Null
        Copy-Item -LiteralPath $target -Destination (Join-Path $bak "$subdir-$($f.Name).bak")
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force
        Write-Host "update $subdir\$($f.Name)   (old copy: backup-$Stamp\$subdir-$($f.Name).bak)"
      }
    } elseif ($PSCmdlet.ShouldProcess($target, 'install')) {
      Copy-Item -LiteralPath $f.FullName -Destination $target
      Write-Host "new    $subdir\$($f.Name)"
    }
  }
}

Write-Host "== agents and commands -> $ConfigDir"
Install-Files (Join-Path $Here 'agents') 'agents'
Install-Files (Join-Path $Here 'commands') 'commands'

# OpenCode globs BOTH `agent\` and `agents\`, and on a name clash the PLURAL copy wins
# (measured on v2.0.10). An older singular copy is then silently dead, which reads
# exactly like "my edit did nothing".
$singular = Join-Path $ConfigDir 'agent'
if (Test-Path -LiteralPath $singular) {
  foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $Here 'agents') -Filter *.md -File)) {
    $dead = Join-Path $singular $f.Name
    if (Test-Path -LiteralPath $dead) { Write-Warning "SHADOWED: $dead is dead - agents\$($f.Name) wins. Delete it." }
  }
}

# ---------------------------------------------------------------- config
Write-Host ""
Write-Host "== config"
$existing = @('opencode.jsonc', 'opencode.json') | ForEach-Object { Join-Path $ConfigDir $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$skillsDir = $null
if ($TeamRepo -and (Test-Path -LiteralPath (Join-Path $TeamRepo 'skills'))) { $skillsDir = Join-Path $TeamRepo 'skills' }
# The path as it must appear INSIDE JSON: native backslashes, each one doubled.
$skillsJson = $null; if ($skillsDir) { $skillsJson = $skillsDir -replace '\\', '\\' }
$webMarker = '    // WEB-RULES (open; install.ps1 -NoWeb puts the four web denies here)'
$webDenies = (@('webfetch', 'websearch', 'execute', 'browser') | ForEach-Object { "    { ""action"": ""$_"", ""resource"": ""*"", ""effect"": ""deny"" }," }) -join "`n"

if ($existing) {
  Write-Host "kept   $existing (never overwritten). Make sure it contains:"
  Write-Host '         "default_agent": "orchestrator"'
  if ($skillsJson) { Write-Host "         ""skills"": [""$skillsJson""]      <- backslashes, not C:/..." }
  if ($NoWeb) { Write-Host '       -NoWeb: add these FIRST inside "permissions": [ ... ] (all four, or it is no lockdown):'; Write-Host $webDenies }
  Write-Host "       Reference: $Here\providers\opencode.work.v2.example.jsonc"
} elseif (-not $BaseUrl -or -not $ModelId) {
  Write-Warning "No config in $ConfigDir and none written: re-run with -BaseUrl <http://host:port/v1> -ModelId <id from /v1/models>."
} else {
  $tpl = [System.IO.File]::ReadAllText((Join-Path $Here 'providers\opencode.work.v2.example.jsonc'))
  $tpl = $tpl.Replace('REPLACE-WITH-SERVED-MODEL-NAME', $ModelId).Replace('REPLACE-WITH-BASE-URL', $BaseUrl.TrimEnd('/'))
  if ($skillsJson) { $tpl = $tpl.Replace('"skills": ["REPLACE-WITH-TEAM-SKILLS-PATH"]', """skills"": [""$skillsJson""]") }
  else { $tpl = $tpl.Replace('"skills": ["REPLACE-WITH-TEAM-SKILLS-PATH"]', '"skills": []') }
  if ($tpl.IndexOf($webMarker) -lt 0) { throw "WEB-RULES marker not found in the config template - refusing to write a config whose web policy is unknown." }
  if ($NoWeb) { $tpl = $tpl.Replace($webMarker, "    // Web locked down by install.ps1 -NoWeb. All four, or it is no lockdown.`n" + $webDenies) }
  $cfg = Join-Path $ConfigDir 'opencode.jsonc'
  if ($PSCmdlet.ShouldProcess($cfg, 'write config')) { [System.IO.File]::WriteAllText($cfg, $tpl, $Utf8NoBom); Write-Host ("new    $cfg   (web: " + $(if ($NoWeb) { 'LOCKED' } else { 'open' }) + ')') }

  # The model id must equal what the server reports, character for character. Ask it.
  try {
    $m = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + '/models') -TimeoutSec 6
    $ids = @($m.data | ForEach-Object { $_.id }) | Where-Object { $_ }
    if ($ids -and ($ids -notcontains $ModelId)) { Write-Warning "The server does not list '$ModelId'. It serves: $($ids -join ', '). Fix ""model"" and the key under ""models"" in $cfg." }
    elseif ($ids) { Write-Host "ok     the server lists '$ModelId'" }
  } catch { Write-Warning "Could not reach $BaseUrl/models to check the model id ($($_.Exception.Message)). If the server needs a key, that is expected; otherwise check the URL." }
}

# ---------------------------------------------------------------- ticket workspaces
Write-Host ""
Write-Host "== ticket workspaces -> $WorkspaceRoot"
if (-not (Test-Path -LiteralPath $WorkspaceRoot)) { if ($PSCmdlet.ShouldProcess($WorkspaceRoot, 'create folder')) { New-Item -ItemType Directory -Force -Path $WorkspaceRoot | Out-Null } }
foreach ($n in @('new-ticket.ps1', 'TICKET.template.md')) {
  $from = Join-Path $Here $n; $target = Join-Path $WorkspaceRoot $n
  if (-not (Test-Path -LiteralPath $target)) { if ($PSCmdlet.ShouldProcess($target, 'install')) { Copy-Item -LiteralPath $from -Destination $target; Write-Host "new    $n" } }
  elseif ((Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $from).Hash) { Write-Host "same   $n" }
  elseif ($n -like '*.md') { Write-Host "kept   $n (it differs from the kit - yours is left alone; the kit's copy is $from)" }
  elseif ($PSCmdlet.ShouldProcess($target, 'replace')) { Copy-Item -LiteralPath $from -Destination $target -Force; Write-Host "update $n" }
}

# ---------------------------------------------------------------- team repo
if ($TeamRepo) {
  Write-Host ""
  Write-Host "== team agents and skills from $TeamRepo"
  & (Join-Path $Here 'sync-team-agents.ps1') -TeamRepo $TeamRepo -ConfigDir $ConfigDir -WhatIf:$WhatIfPreference
}

Write-Host ""
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) { Write-Warning 'opencode is not on PATH.' }
elseif ($Reload) {
  if ($PSCmdlet.ShouldProcess('opencode', 'reload configuration')) { & opencode reload | Out-Null }
  Write-Host "Reloaded. Verify:  opencode debug agents   (an empty list right after a restart is normal - ask again)"
} else {
  Write-Host "NOT reloaded: a reload aborts tool calls in any session that is working right now."
  Write-Host "When nothing is running:  opencode reload   then verify with:  opencode debug agents"
}
Write-Host "Then, per ticket:  cd `"$WorkspaceRoot`" ; .\new-ticket.ps1 PROJ-1234 `"short title`" -Repo C:\repos\<repo> -Open"
Write-Host "OpenCode is opened in the TICKET folder, never in the repository; /ticket starts - or continues - the pipeline."
