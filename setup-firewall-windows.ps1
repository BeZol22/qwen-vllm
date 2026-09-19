#Requires -Version 5.1
<#
.SYNOPSIS
  Open port 8000 to the home LAN only, so the MacBook can reach llama-server.

.DESCRIPTION
  The Windows counterpart to the ufw rules in REBUILD.md. Idempotent: re-running
  reports "0 changed" once the box is in the right state, the same way
  configure-openwebui.py does.

  THERE ARE TWO STEPS AND THE SECOND ONE IS THE ONE PEOPLE MISS. A firewall rule
  scoped to the Private profile does nothing while the network itself is
  classified Public -- Windows drops inbound regardless. On this box the Ethernet
  adapter was Public and an (already present) allow rule for 8000/tcp was simply
  inert, which reads exactly like "the firewall rule does not work".

  SCOPING MATTERS MORE THAN IT LOOKS. The pre-existing rule here was
  RemoteAddress=Any. On the Private profile that is not just "the LAN": it is
  every network Windows ever classifies as Private, which on this box includes
  the NordLynx VPN adapter (10.5.0.2/16). Scoping to the actual LAN subnet keeps
  the port off the tunnel no matter how a profile gets classified later.

  IPv6 is not a concern for this deployment, unlike the vLLM one: llama-server
  binds 0.0.0.0, which is IPv4-only, so the globally routable IPv6 address is not
  listening at all. See docs/notes/windows-native-llamacpp.md.

.PARAMETER Port
  TCP port to open. Default 8000, matching serve-qwen38-windows.ps1.

.PARAMETER Subnet
  CIDR allowed to connect. Default: derived from the adapter holding the default
  route, so a router change does not silently leave a stale subnet behind.

.PARAMETER RetireOld
  Also disable the legacy unscoped 'vLLM Qwen3.6 (8000 tcp Private)' rule.
  Disabled, not deleted -- Enable-NetFirewallRule puts it back.

.PARAMETER DryRun
  Print what would change and touch nothing.

.EXAMPLE
  .\setup-firewall-windows.ps1 -DryRun
  .\setup-firewall-windows.ps1
#>
[CmdletBinding()]
param(
    [int]$Port = 8000,
    [string]$Subnet,
    [string]$InterfaceAlias,
    [switch]$RetireOld,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RuleName = "llama-server LAN ($Port/tcp)"
$LegacyRule = 'vLLM Qwen3.6 (8000 tcp Private)'

# --- elevation ---------------------------------------------------------------
# Everything below needs admin. Relaunch with -NoExit so the results stay on
# screen instead of flashing past in a window that closes itself.
$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $DryRun) {
    Write-Host "not elevated -- relaunching as administrator (accept the UAC prompt)" -ForegroundColor Yellow
    $a = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $a += "-$($kv.Key)" } }
        else { $a += @("-$($kv.Key)", "$($kv.Value)") }
    }
    Start-Process powershell -Verb RunAs -ArgumentList $a
    return
}

# --- work out which adapter and subnet ---------------------------------------
if (-not $InterfaceAlias) {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { throw "no default route found -- pass -InterfaceAlias explicitly" }
    $InterfaceAlias = (Get-NetAdapter -InterfaceIndex $route.ifIndex).Name
}
$ip = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 |
      Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
if (-not $ip) { throw "no IPv4 address on '$InterfaceAlias'" }

if (-not $Subnet) {
    $o = $ip.IPAddress.Split('.')
    # /24 is the honest default for a home LAN; pass -Subnet for anything else.
    $Subnet = "$($o[0]).$($o[1]).$($o[2]).0/$(if ($ip.PrefixLength -ge 24) { 24 } else { $ip.PrefixLength })"
}

Write-Host ""
Write-Host "interface : $InterfaceAlias  ($($ip.IPAddress)/$($ip.PrefixLength))"
Write-Host "allowing  : $Subnet  ->  TCP $Port"
Write-Host "endpoint  : http://$($ip.IPAddress):$Port/v1"
if ($DryRun) { Write-Host "MODE      : DRY RUN, nothing will change" -ForegroundColor Yellow }
Write-Host ""

$changed = 0
function Step($label, $already, $action) {
    if ($already) { Write-Host ("  ok       {0}" -f $label); return }
    if ($DryRun)  { Write-Host ("  WOULD    {0}" -f $label) -ForegroundColor Yellow; $script:changed++; return }
    & $action
    Write-Host ("  CHANGED  {0}" -f $label) -ForegroundColor Green
    $script:changed++
}

# --- 1. the network must be Private ------------------------------------------
$profileNow = (Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias).NetworkCategory
Step "network profile Private (was $profileNow)" ($profileNow -eq 'Private') {
    Set-NetConnectionProfile -InterfaceAlias $InterfaceAlias -NetworkCategory Private
}

# --- 2. the scoped inbound rule ----------------------------------------------
# Windows stores a CIDR back as a dotted netmask: you write 192.168.178.0/24 and
# Get-NetFirewallAddressFilter hands you 192.168.178.0/255.255.255.0. Comparing
# the two as strings never matches, so the rule looks wrong on every run and the
# script deletes and recreates a perfectly good rule forever. Normalise first --
# this is what makes "0 changed" actually mean nothing needed doing.
function Normalize-Cidr($a) {
    if ($a -match '^(\d+\.\d+\.\d+\.\d+)/(\d+\.\d+\.\d+\.\d+)$') {
        $bits = ($matches[2].Split('.') | ForEach-Object {
            [Convert]::ToString([int]$_, 2).ToCharArray() | Where-Object { $_ -eq '1' }
        }).Count
        return "$($matches[1])/$bits"
    }
    return "$a"
}

$rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
$ruleOk = $false
if ($rule) {
    $af = $rule | Get-NetFirewallAddressFilter
    $pf = $rule | Get-NetFirewallPortFilter
    $ruleOk = ($rule.Enabled -eq 'True') -and ($rule.Action -eq 'Allow') -and
              ($rule.Direction -eq 'Inbound') -and
              ((Normalize-Cidr $af.RemoteAddress) -eq (Normalize-Cidr $Subnet)) -and
              ("$($pf.LocalPort)" -eq "$Port")
}
Step "inbound allow rule '$RuleName' scoped to $Subnet" $ruleOk {
    if ($rule) { Remove-NetFirewallRule -DisplayName $RuleName }
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Port -RemoteAddress $Subnet -Profile Private | Out-Null
}

# --- 3. the legacy unscoped rule ---------------------------------------------
$old = Get-NetFirewallRule -DisplayName $LegacyRule -ErrorAction SilentlyContinue
if ($old) {
    if ($RetireOld) {
        Step "legacy rule '$LegacyRule' disabled" ($old.Enabled -ne 'True') {
            Disable-NetFirewallRule -DisplayName $LegacyRule
        }
    } elseif ($old.Enabled -eq 'True') {
        $oaf = $old | Get-NetFirewallAddressFilter
        Write-Host ("  NOTE     legacy rule '{0}' is enabled with RemoteAddress={1}" -f $LegacyRule, $oaf.RemoteAddress) -ForegroundColor Yellow
        Write-Host    "           it re-opens this port to every Private network, VPN adapters included."
        Write-Host    "           Re-run with -RetireOld to disable it (reversible)."
    }
}

# --- verify ------------------------------------------------------------------
Write-Host ""
Write-Host "$changed changed"
Write-Host ""
$listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listen) {
    Write-Host "listening : $(($listen.LocalAddress | Sort-Object -Unique) -join ', ') : $Port"
    Write-Host ""
    Write-Host "test from the MacBook:"
    Write-Host "    curl http://$($ip.IPAddress):$Port/v1/models"
    Write-Host "and point OpenCode at  http://$($ip.IPAddress):$Port/v1"
} else {
    Write-Host "NOTE: nothing is listening on $Port yet -- start serve-qwen38-windows.ps1." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "If the MacBook still cannot connect, disconnect NordVPN and retry BEFORE"
Write-Host "touching these rules -- the tunnel is the more common cause."
