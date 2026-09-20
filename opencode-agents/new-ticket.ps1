<#
.SYNOPSIS
  Create the workspace folder for one ticket - the folder you open OpenCode in.

.DESCRIPTION
  The agents' paperwork (TICKET.md, PLAN.md, REVIEW.md, PROGRESS.md, your notes) lives in
  a folder of its own per ticket, OUTSIDE every code repository:

    <Root>\<KEY>-<title-as-slug>\
        TICKET.md     the specification; this script fills in the title and the Code section
        notes\        drop the raw material here: Jira export, meeting notes, mails, logs
        <KEY>.code-workspace   VS Code multi-root workspace: this folder + the repositories

  The code repositories are only REFERENCED (TICKET.md, "## Code"); nothing is written
  into them by this script, and the only agent that can write there is the coder.
  Running it again for an existing ticket changes nothing - it just tells you where it is
  (and opens it with -Open), so it doubles as "take me back to that ticket".

  <Root> defaults to the folder this script was installed into (install.ps1 puts it in
  Documents\opencode), or to Documents\opencode when it is run from the kit itself.

.EXAMPLE
  .\new-ticket.ps1 PROJ-1234 "Order export times out for large tenants" -Repo C:\repos\orders -Open
.EXAMPLE
  .\new-ticket.ps1 PROJ-1301 "Shared retry policy" -Repo C:\repos\orders, C:\repos\platform-lib
.EXAMPLE
  .\new-ticket.ps1 PROJ-1234 "Order export times out for large tenants" -Open     # back to an existing ticket
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory, Position = 0)][string]$Key,
  [Parameter(Position = 1)][string]$Title = '',
  [string[]]$Repo = @(),     # required for a NEW ticket; an existing one already names its code roots
  [string]$Root,
  [switch]$Open
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 puts a BOM in front of -Encoding utf8 output; write without one.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not $Root) {
  # GetFolderPath, not $HOME\Documents: on a work machine Documents is often redirected
  # (OneDrive), and that is the folder the user means.
  if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'agents')) { $Root = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'opencode' }
  else { $Root = $PSScriptRoot }
}
$template = Join-Path $PSScriptRoot 'TICKET.template.md'
if (-not (Test-Path -LiteralPath $template)) { throw "TICKET.template.md not found next to this script ($PSScriptRoot)." }

$slug = ($Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).TrimEnd('-') }
$name = ($Key.Trim() -replace '[\\/:*?"<>|\s]+', '-')
if ($slug) { $name = "$name-$slug" }
$ws = Join-Path $Root $name
$ticket = Join-Path $ws 'TICKET.md'
$isNew = -not (Test-Path -LiteralPath $ticket)
if ($isNew -and -not $Repo) { throw "A new ticket needs -Repo <path to the repository>[, <another>]: the agents find the code through TICKET.md." }

# ---------------------------------------------------------------- the code roots
# `powershell -File new-ticket.ps1 -Repo a,b` hands over ONE string; take it apart.
$Repo = @($Repo | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$codeLines = @()
$vsFolders = @()
foreach ($r in $Repo) {
  if (-not (Test-Path -LiteralPath $r -PathType Container)) { throw "No such folder: $r" }
  $full = (Resolve-Path -LiteralPath $r).Path.TrimEnd('\')
  # Forward slashes: they work in PowerShell, in Git Bash and in git itself. A backslash
  # path that reaches bash unquoted loses its separators (measured: OpenCode on Windows
  # may run the agents' commands in Git Bash).
  $fwd = $full -replace '\\', '/'
  $note = ''
  if (Get-Command git -ErrorAction SilentlyContinue) {
    $top = (& git -C $full rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if (-not $top) { Write-Warning "$full is not inside a git repository - the reviewer finds the change through 'git diff HEAD' and will see nothing here." }
    else {
      $branch = (& git -C $full branch --show-current 2>$null | Out-String).Trim()
      if ($branch) { $note = " (branch when created: $branch)" }
      $dirty = @(& git -C $full status --porcelain 2>$null).Count
      if ($isNew -and $dirty -gt 0) { Write-Warning "$full has $dirty uncommitted change(s). The reviewer reads 'git diff HEAD' and will take them for part of this ticket - commit or stash them first." }
    }
  }
  $codeLines += "- $fwd$note - <what lives there>"
  $vsFolders += @{ name = (Split-Path -Leaf $full); path = $fwd }
}

# ---------------------------------------------------------------- the workspace
if (-not $isNew) {
  Write-Host "exists $ws   (nothing changed - /ticket in there continues it)"
} else {
  if ($PSCmdlet.ShouldProcess($ws, 'create ticket workspace')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $ws 'notes') | Out-Null
    $text = [System.IO.File]::ReadAllText($template)
    $heading = "# $($Key.Trim())"; if ($Title) { $heading = "$heading $($Title.Trim())" }
    $text = $text.Replace('# <TICKET-KEY> <one-line title>', $heading)
    $text = $text.Replace('- <C:/repos/example> - <what lives there>', ($codeLines -join "`n"))
    [System.IO.File]::WriteAllText($ticket, $text, $Utf8NoBom)
    # One VS Code window for both sides: the ticket's paperwork and the repositories, whose
    # source-control view shows the change as the coder makes it.
    $vs = @{ folders = @(@{ name = "$($Key.Trim()) (ticket)"; path = '.' }) + $vsFolders }
    [System.IO.File]::WriteAllText((Join-Path $ws "$($Key.Trim() -replace '[^A-Za-z0-9._-]+', '-').code-workspace"), ($vs | ConvertTo-Json -Depth 4), $Utf8NoBom)
    Write-Host "new    $ws"
    Write-Host "       TICKET.md   fill it in - or drop the raw material into notes\ and let /intake write it"
    Write-Host "       notes\      Jira export, meeting notes, mails, logs (text files)"
    Write-Host "       *.code-workspace   open it in VS Code: the ticket folder and the repositories in one window"
  }
}

Write-Host ""
Write-Host "Next:  cd `"$ws`" ; opencode"
Write-Host "       /intake     notes\ -> TICKET.md, with the open questions        (optional)"
Write-Host "       /ticket     plan -> you approve -> code -> review -> refactor; also CONTINUES a ticket"
Write-Host "       The change appears in the code repositories, uncommitted: read it in VS Code, commit it yourself."

if ($Open -and (Test-Path -LiteralPath $ws)) {
  if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) { Write-Warning 'opencode is not on PATH.' }
  else { Push-Location -LiteralPath $ws; try { & opencode } finally { Pop-Location } }
}
