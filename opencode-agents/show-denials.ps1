<#
.SYNOPSIS
  Show which tool calls OpenCode refused or failed in recent sessions, by agent.

.DESCRIPTION
  "Permission denied: shell" in a session is normal in itself - it is a deny rule doing its
  job. What matters is WHICH command was refused:

    a guard rail working     git commit, a write through the shell by a read-only agent ...
    a harmless command       should not happen: every working agent allows its shell by
                             default and denies only history-changing and destructive
                             commands. If you see one, the deny pattern is too broad.
    a compound command       `a; b` or `a | b` is refused AS A WHOLE when any one part is
                             not permitted

  Read-only: it only asks the running OpenCode service for session data. It also lists the
  tools each primary agent used, because an orchestrator that uses websearch/execute/read
  heavily is doing work it should delegate.

.EXAMPLE
  .\show-denials.ps1
.EXAMPLE
  .\show-denials.ps1 -Sessions 40 -ShowAll
#>
[CmdletBinding()]
param(
  [int]$Sessions = 20,     # how many of the most recent sessions (children included) to scan
  [switch]$ShowAll         # also list failures that are not permission denials
)
$ErrorActionPreference = 'Stop'

function Get-Api([string]$path) {
  $raw = (& opencode api GET $path 2>$null | Out-String).Trim()
  if (-not $raw) { return @() }
  try { $j = $raw | ConvertFrom-Json } catch { return @() }
  if ($j.PSObject.Properties.Name -contains 'data') { return @($j.data) } else { return @($j) }
}

$all = @(Get-Api '/api/session' | Select-Object -First $Sessions)
if (-not $all) { Write-Warning 'No sessions returned. Is the OpenCode service running? (A service that has just started answers with an empty list - try again.)'; return }

$rows = @()
foreach ($s in $all) {
  foreach ($m in (Get-Api "/api/session/$($s.id)/message")) {
    foreach ($c in @($m.content)) {
      if (-not $c -or $c.type -ne 'tool') { continue }
      $state = ($c.state | ConvertTo-Json -Depth 5 -Compress)
      $what = $c.state.input.command
      if (-not $what) { $what = ($c.state.input | ConvertTo-Json -Depth 3 -Compress) }
      $what = ([string]$what -replace '\s+', ' ')
      if ($what.Length -gt 160) { $what = $what.Substring(0, 157) + '...' }
      $rows += [pscustomobject]@{
        Agent   = $s.agent
        Primary = (-not $s.parentID)
        Session = $s.title
        Tool    = $c.name
        Status  = $c.state.status
        Denied  = ($state -match 'Permission denied')
        Aborted = ($state -match '"type":"aborted"')
        What    = $what
      }
    }
  }
}

"Scanned $($all.Count) sessions, $($rows.Count) tool calls: " + (($rows | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ')
""
$denied = @($rows | Where-Object Denied)
if (-not $denied) { 'No permission denials.' }
foreach ($g in ($denied | Group-Object Agent | Sort-Object Count -Descending)) {
  "== $($g.Name): $($g.Count) denied"
  foreach ($r in $g.Group) { "   [$($r.Tool)] $($r.What)" }
}

$aborted = @($rows | Where-Object Aborted)
if ($aborted) { ""; "== $($aborted.Count) call(s) ABORTED - the location shut down under them. Someone ran 'opencode reload' (or restarted the service) while a session was working." }

if ($ShowAll) {
  $other = @($rows | Where-Object { $_.Status -eq 'error' -and -not $_.Denied -and -not $_.Aborted })
  if ($other) { ""; "== other failures"; foreach ($r in $other) { "   $($r.Agent) [$($r.Tool)] $($r.What)" } }
}

""
"== tools used by primary agents (an orchestrator should show little besides 'subagent')"
foreach ($g in ($rows | Where-Object Primary | Group-Object Agent)) {
  "   {0,-14} {1}" -f $g.Name, (($g.Group | Group-Object Tool | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ')
}
