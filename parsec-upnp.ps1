<#
.SYNOPSIS
    Opens (or removes) the UPnP port forwardings a Parsec client needs on a NAT router.

.DESCRIPTION
    Some routers sit behind a carrier-grade NAT (the router's own WAN address is in
    100.64.0.0/10). Parsec on Windows detects this, decides the router is useless and
    silently skips creating its own UPnP mapping. Android clients do not care and
    create the mapping anyway - which is why the same host works from a phone but
    not from the PC.

    This script creates those UPnP forwardings itself, so the router knows where to
    deliver the incoming UDP traffic:
        * the Parsec client port (auto-detected from the Parsec log),
        * the Parsec host port range (8000-8010 by default).

    The script discovers the router over SSDP, walks the UPnP device description to
    find the WANIPConnection service, and talks to it over SOAP. No administrator
    rights are required - UPnP IGD is unauthenticated by design.

.PARAMETER Mode
    Add    (default) - create the missing forwardings, leave existing ones alone.
    List             - only print what is currently on the router.
    Remove           - delete the forwardings this machine created.

.PARAMETER ClientPort
    Parsec client UDP port. When 0 (default) the script reads it from the Parsec log
    and falls back to 30640.

.PARAMETER HostRange
    Parsec host port range to forward. Default: 8000-8010.

.EXAMPLE
    .\parsec-upnp.ps1

.EXAMPLE
    .\parsec-upnp.ps1 -Mode List

.EXAMPLE
    .\parsec-upnp.ps1 -Mode Remove

.NOTES
    Tested with Parsec 150-105c behind a Huawei HG8245X6-10 (Netia, CGNAT).
#>
[CmdletBinding()]
param(
    [ValidateSet('Add', 'List', 'Remove')]
    [string]$Mode = 'Add',

    [int]$ClientPort = 0,

    [string]$HostRange = '8000-8010'
)

$ErrorActionPreference = 'Stop'

function Write-Step($text) { Write-Host $text -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host $text -ForegroundColor Green }
function Write-Warn2($text){ Write-Host $text -ForegroundColor Yellow }
function Write-Err($text)  { Write-Host $text -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. Local network
# ---------------------------------------------------------------------------
Write-Step "[1/5] Detecting the local network..."

$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Sort-Object RouteMetric | Select-Object -First 1

if (-not $defaultRoute) {
    Write-Err '  No default route found. Are you connected to a network?'
    exit 1
}

$netCfg = Get-NetIPConfiguration -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue
$localIp = ($netCfg.IPv4Address | Where-Object { $_.IPAddress -notlike '169.254.*' } |
           Select-Object -First 1).IPAddress
$gateway = ($netCfg.IPv4DefaultGateway | Select-Object -First 1).NextHop

Write-Host ("  Interface : {0}" -f $netCfg.InterfaceAlias)
Write-Host ("  This PC   : {0}" -f $localIp)
Write-Host ("  Router    : {0}" -f $gateway)

# ---------------------------------------------------------------------------
# 2. SSDP discovery
# ---------------------------------------------------------------------------
Write-Step "`n[2/5] Looking for the router over SSDP..."

function Find-IgdLocation {
    $mSearch = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 2`r`n" +
               "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1`r`n`r`n"
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = 3000
        $bytes = [Text.Encoding]::ASCII.GetBytes($mSearch)
        $multicast = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('239.255.255.250')), 1900
        [void]$udp.Send($bytes, $bytes.Length, $multicast)
        $remote = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
        $response = [Text.Encoding]::ASCII.GetString($udp.Receive([ref]$remote))
        return ([regex]::Match($response, 'LOCATION:\s*(\S+)')).Groups[1].Value
    }
    catch { return $null }
    finally { $udp.Close() }
}

$location = Find-IgdLocation
if (-not $location) {
    Write-Err '  No SSDP reply. The router probably has UPnP disabled.'
    Write-Err '  Enable UPnP in the router web UI and run this script again.'
    exit 1
}
Write-Host ("  Description: {0}" -f $location)

# ---------------------------------------------------------------------------
# 3. Device description -> WANIPConnection service
# ---------------------------------------------------------------------------
Write-Step "`n[3/5] Reading the device description..."

[xml]$deviceXml = (Invoke-WebRequest -Uri $location -UseBasicParsing -TimeoutSec 8).Content
$rootUrl = $location -replace '/[^/]*$', ''

$script:wanService = $null
function Find-Service($node, $rootUrl) {
    if ($null -eq $node) { return }
    foreach ($svc in @($node.serviceList.service)) {
        if ($null -eq $svc) { continue }
        if ($svc.serviceType -match 'WANIPConnection|WANPPPConnection') {
            $url = if ($svc.controlURL -like 'http*') { $svc.controlURL } else { "$rootUrl$($svc.controlURL)" }
            $script:wanService = [pscustomobject]@{ Type = $svc.serviceType; Url = $url }
        }
    }
    foreach ($child in @($node.deviceList.device)) { Find-Service $child $rootUrl }
}
Find-Service $deviceXml.root.device $rootUrl

if (-not $script:wanService) {
    Write-Err '  This router does not expose a WANIPConnection service.'
    exit 1
}
Write-Host ("  Service    : {0}" -f $script:wanService.Url)

function Invoke-IgdSoap([string]$Action, [string]$Body) {
    $envelope = '<?xml version="1.0"?>' +
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' +
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">' +
        "<s:Body><u:$Action xmlns:u=`"$($script:wanService.Type)`">$Body</u:$Action></s:Body></s:Envelope>"
    try {
        (Invoke-WebRequest -Uri $script:wanService.Url -Method POST `
            -Headers @{ SOAPACTION = "`"$($script:wanService.Type)#$Action`"" } `
            -ContentType 'text/xml' -Body $envelope -UseBasicParsing -TimeoutSec 8).Content
    }
    catch { "ERROR: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# 4. Parsec client port
# ---------------------------------------------------------------------------
Write-Step "`n[4/5] Resolving the Parsec client port..."

if ($ClientPort -eq 0) {
    $logPath = Join-Path $env:APPDATA 'Parsec\log_cl.txt'
    if (Test-Path $logPath) {
        $match = Select-String -Path $logPath -Pattern '"lan":true,"port":(\d+)' -AllMatches |
                 Select-Object -Last 1
        if ($match) { $ClientPort = [int]$match.Matches[0].Groups[1].Value }
    }
    if ($ClientPort -eq 0) {
        $ClientPort = 30640
        Write-Warn2 '  Not found in the Parsec log - using the default 30640.'
        Write-Warn2 '  Start Parsec and try to connect once, then run this script again.'
    }
    else { Write-Ok ("  Detected from the Parsec log: {0}" -f $ClientPort) }
}
else { Write-Host ("  Provided on the command line: {0}" -f $ClientPort) }

$hostPorts = @()
if ($HostRange -match '^(\d+)-(\d+)$') { $hostPorts = [int]$Matches[1]..[int]$Matches[2] }
$allPorts = @($ClientPort) + $hostPorts

# ---------------------------------------------------------------------------
# 5. Current mappings / action
# ---------------------------------------------------------------------------
Write-Step "`n[5/5] Forwardings currently on the router:"

$existing = @()
for ($i = 0; $i -lt 64; $i++) {
    $response = Invoke-IgdSoap 'GetGenericPortMappingEntry' "<NewPortMappingIndex>$i</NewPortMappingIndex>"
    if ($response -notmatch '<NewExternalPort>') { break }
    $existing += [pscustomobject]@{
        External = [int]([regex]::Match($response, '<NewExternalPort>(.*?)</NewExternalPort>')).Groups[1].Value
        Protocol = ([regex]::Match($response, '<NewProtocol>(.*?)</NewProtocol>')).Groups[1].Value
        Client   = ([regex]::Match($response, '<NewInternalClient>(.*?)</NewInternalClient>')).Groups[1].Value
        Internal = [int]([regex]::Match($response, '<NewInternalPort>(.*?)</NewInternalPort>')).Groups[1].Value
        Desc     = ([regex]::Match($response, '<NewPortMappingDescription>(.*?)</NewPortMappingDescription>')).Groups[1].Value
    }
}

if ($existing.Count -eq 0) { Write-Host '  (none)' }
else {
    foreach ($m in $existing) {
        $mark = if ($m.Client -eq $localIp) { '  <-- this PC' } else { '' }
        Write-Host ("  {0,-4} {1,-6} -> {2}:{3}   [{4}]{5}" -f $m.Protocol, $m.External, $m.Client, $m.Internal, $m.Desc, $mark)
    }
}

$wanIp = ([regex]::Match((Invoke-IgdSoap 'GetExternalIPAddress' ''),
          '<NewExternalIPAddress>(.*?)</NewExternalIPAddress>')).Groups[1].Value
if ($wanIp) {
    Write-Host ("`n  Router WAN address: {0}" -f $wanIp)
    if ($wanIp -match '^(10\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)') {
        Write-Warn2 '  Note: that is a private/CGNAT address - this is exactly the case'
        Write-Warn2 '  where Parsec skips UPnP on its own. The forwardings below are the fix.'
    }
}

if ($Mode -eq 'List') { Write-Ok "`nList mode - nothing was changed.`n"; exit 0 }

if ($Mode -eq 'Remove') {
    Write-Step "`nRemoving the forwardings created for this PC..."
    $mine = $existing | Where-Object { $_.Client -eq $localIp -and $_.Desc -like 'Parsec-*' }
    if (-not $mine) { Write-Warn2 '  Nothing to remove.'; exit 0 }
    foreach ($m in $mine) {
        $body = "<NewRemoteHost></NewRemoteHost><NewExternalPort>$($m.External)</NewExternalPort>" +
                "<NewProtocol>$($m.Protocol)</NewProtocol>"
        $result = Invoke-IgdSoap 'DeletePortMapping' $body
        if ($result -match 'ERROR') { Write-Err ("  {0}/{1}: {2}" -f $m.External, $m.Protocol, $result) }
        else { Write-Ok ("  removed {0}/{1}" -f $m.External, $m.Protocol) }
    }
    Write-Host ''
    exit 0
}

Write-Step "`nAdding missing forwardings..."
$added = 0; $skipped = 0; $failed = 0

foreach ($port in ($allPorts | Select-Object -Unique)) {
    $description = if ($port -eq $ClientPort) { 'Parsec-client' } else { 'Parsec-host' }

    $alreadyOurs = $existing | Where-Object {
        $_.External -eq $port -and $_.Protocol -eq 'UDP' -and $_.Client -eq $localIp -and $_.Internal -eq $port
    }
    if ($alreadyOurs) { $skipped++; continue }

    $takenByOther = $existing | Where-Object { $_.External -eq $port -and $_.Protocol -eq 'UDP' -and $_.Client -ne $localIp }
    if ($takenByOther) {
        Write-Warn2 ("  UDP {0,-6} skipped - already used by {1}" -f $port, $takenByOther[0].Client)
        $failed++
        continue
    }

    $body = "<NewRemoteHost></NewRemoteHost><NewExternalPort>$port</NewExternalPort>" +
            "<NewProtocol>UDP</NewProtocol><NewInternalPort>$port</NewInternalPort>" +
            "<NewInternalClient>$localIp</NewInternalClient><NewEnabled>1</NewEnabled>" +
            "<NewPortMappingDescription>$description</NewPortMappingDescription>" +
            "<NewLeaseDuration>0</NewLeaseDuration>"
    $result = Invoke-IgdSoap 'AddPortMapping' $body

    if ($result -match 'ERROR') { Write-Err ("  UDP {0,-6} failed: {1}" -f $port, $result); $failed++ }
    else { Write-Ok ("  UDP {0,-6} added ({1})" -f $port, $description); $added++ }
}

Write-Host ("`nDone: {0} added, {1} already present, {2} failed." -f $added, $skipped, $failed) -ForegroundColor Cyan
if ($added -gt 0) { Write-Ok 'Start Parsec and connect now.' } else { Write-Ok 'Everything was already in place - nothing changed.' }
Write-Host ''
