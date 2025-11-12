<# 
.SYNOPSIS
Test connectivity and SNMPv2c communication to a Xerox (or other SNMP-enabled) device.

.DESCRIPTION
Prompts for an IP address (and optionally community string), checks TCP 443 reachability,
then sends a valid SNMPv2c GetRequest for sysDescr.0 (1.3.6.1.2.1.1.1.0) on UDP/161.
It also performs a lightweight SNMP walk of the Printer-MIB supplies table:
  - prtMarkerSuppliesDescription: 1.3.6.1.2.1.43.11.1.1.9
  - prtMarkerSuppliesLevel:       1.3.6.1.2.1.43.11.1.1.8
  - prtMarkerSuppliesMaxCapacity: 1.3.6.1.2.1.43.11.1.1.7

The supplies walk is best-effort and stops when it leaves the base OID or reaches a step limit.

.NOTES
- Requires no external modules; builds minimal SNMPv2c PDUs via .NET byte arrays.
- UDP/162 (traps) is not queried (it’s for unsolicited messages).
#>


# ---------------------------
# Input
# ---------------------------
$ip = Read-Host "Enter the IP address of the Xerox/device to test"
if ([string]::IsNullOrWhiteSpace($ip)) {
    Write-Host "No IP entered. Exiting." -ForegroundColor Red
    exit 1
}


$community = Read-Host "Enter SNMP community string (default = public)"
if ([string]::IsNullOrWhiteSpace($community)) { $community = "public" }

# ---------------------------
# Local endpoint (CIDR) used to reach target
# ---------------------------
function Get-LocalIPv4CIDRForDestination {
    param([string]$DestinationIp)
    try {
        $route = Get-NetRoute -DestinationPrefix "$DestinationIp/32" -AddressFamily IPv4 -ErrorAction Stop |
                 Sort-Object RouteMetric, PrefSource -Descending:$false | Select-Object -First 1
        if ($null -ne $route) {
            $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 |
                  Where-Object { $null -ne $_.IPAddress -and $_.SkipAsSource -ne $true } |
                  Sort-Object -Property PrefixLength -Descending:$true | Select-Object -First 1
            if ($ip) { return "{0}/{1}" -f $ip.IPAddress, $ip.PrefixLength }
        }
    } catch { }
    # Fallback: pick primary interface with default gateway
    $primary = Get-NetIPConfiguration | Where-Object { $null -ne $_.IPv4DefaultGateway } |
               Select-Object -First 1
    if ($primary -and $primary.IPv4Address -and $primary.IPv4Address.IPAddress) {
        $addr = $primary.IPv4Address.IPAddress
        $pl = ($primary.IPv4Address | Select-Object -First 1).PrefixLength
        return "{0}/{1}" -f $addr, $pl
    }
    # Last resort: any IPv4 address
    $any = Get-NetIPAddress -AddressFamily IPv4 | Select-Object -First 1
    if ($any) { return "{0}/{1}" -f $any.IPAddress, $any.PrefixLength }
    return "(unknown)"
}

$localCIDR = Get-LocalIPv4CIDRForDestination -DestinationIp $ip
Write-Host ("Local endpoint for this test: {0}" -f $localCIDR) -ForegroundColor DarkCyan

# ---------------------------
# TCP 443 Reachability Test
# ---------------------------
Write-Host "`n=== Connectivity test to $ip ===" -ForegroundColor Cyan
Write-Host "Checking TCP port 443 (HTTPS)..." -ForegroundColor Yellow
$tcp = Test-NetConnection -ComputerName $ip -Port 443 -WarningAction SilentlyContinue
if ($tcp.TcpTestSucceeded) {
    Write-Host "✅ TCP 443 reachable on $ip" -ForegroundColor Green
} else {
    Write-Host "❌ TCP 443 NOT reachable on $ip" -ForegroundColor Red
}

# ---------------------------
# Helpers for SNMP encoding
# ---------------------------
function ConvertTo-BerLength([int]$len) {
    if ($len -lt 128) { return ,([byte]$len) }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $tmp = [System.Collections.Generic.List[byte]]::new()
    $n = $len
    while ($n -gt 0) {
        $tmp.Add([byte]($n -band 0xFF))
        $n = $n -shr 8
    }
    $tmpArr = $tmp.ToArray()
    [Array]::Reverse($tmpArr)
    $bytes.Add([byte](0x80 -bor $tmpArr.Length))
    $bytes.AddRange($tmpArr)
    return $bytes.ToArray()
}

function ConvertTo-BerInteger([int]$value) {
    $v = $value
    $tmp = [System.Collections.Generic.List[byte]]::new()
    if ($v -eq 0) { $tmp.Add(0x00) }
    else {
        while ($v -ne 0 -and $v -ne -1) {
            $tmp.Add([byte]($v -band 0xFF))
            $v = $v -shr 8
        }
        $msb = $tmp[$tmp.Count-1]
        if (($value -ge 0 -and ($msb -band 0x80) -ne 0) -or ($value -lt 0 -and ($msb -band 0x80) -eq 0)) {
            $tmp.Add(($value -lt 0) ? 0xFF : 0x00)
        }
        $tmpArr = $tmp.ToArray(); [Array]::Reverse($tmpArr); $tmp = [System.Collections.Generic.List[byte]]::new(); $tmp.AddRange($tmpArr)
    }
    $content = $tmp.ToArray()
    return ,0x02 + (ConvertTo-BerLength $content.Length) + $content
}

function ConvertTo-BerOctetString([byte[]]$bytes) {
    return ,0x04 + (ConvertTo-BerLength $bytes.Length) + $bytes
}

function ConvertTo-BerNull() { return ,0x05,0x00 }

function ConvertTo-BerOid([string]$oid) {
    # Expect dotted string like 1.3.6.1.2.1.1.1.0
    $parts = $oid.Split('.') | ForEach-Object {[int]$_}
    if ($parts.Length -lt 2) { throw "Invalid OID: $oid" }
    $first = ($parts[0] * 40) + $parts[1]
    $body = New-Object System.Collections.Generic.List[byte]
    $body.Add([byte]$first)
    for ($i=2; $i -lt $parts.Length; $i++) {
        $val = [uint32]$parts[$i]
        $stack = New-Object System.Collections.Generic.List[byte]
        $stack.Add([byte]($val -band 0x7F))
        $val = $val -shr 7
        while ($val -gt 0) {
            $stack.Add([byte](0x80 -bor ($val -band 0x7F)))
            $val = $val -shr 7
        }
        $arr = $stack.ToArray()
        [Array]::Reverse($arr)
        $body.AddRange($arr)
    }
    $content = $body.ToArray()
    return ,0x06 + (ConvertTo-BerLength $content.Length) + $content
}

function New-BerSequence([byte[]]$content) {
    return ,0x30 + (ConvertTo-BerLength $content.Length) + $content
}

function New-RequestId() { return Get-Random -Minimum 100000 -Maximum 999999 }

function New-SnmpVarBind([string]$oid,[byte[]]$valueBytes) {
    $vb = (ConvertTo-BerOid $oid) + $valueBytes
    return (New-BerSequence $vb)
}

function New-SnmpVarBindList([byte[][]]$varBinds) {
    $content = @()
    foreach ($vb in $varBinds) { $content += $vb }
    return (New-BerSequence $content)
}

function New-SnmpGetPdu([byte]$pduTag,[int]$requestId,[byte[][]]$varBinds) {
    $pduContent = (ConvertTo-BerInteger $requestId) + (ConvertTo-BerInteger 0) + (ConvertTo-BerInteger 0) + (New-SnmpVarBindList $varBinds)
    return ,$pduTag + (ConvertTo-BerLength $pduContent.Length) + $pduContent
}

function New-SnmpV2CPacket([string]$community,[byte[]]$pdu) {
    $version = (ConvertTo-BerInteger 1)            # v2c
    $comm    = (ConvertTo-BerOctetString ([System.Text.Encoding]::ASCII.GetBytes($community)))
    return (New-BerSequence ($version + $comm + $pdu))
}

# ---------------------------
# SNMP Send/Receive
# ---------------------------
function Invoke-SnmpRequest {
    param(
        [string]$TargetIp,
        [string]$Community,
        [byte]$PduTag,                 # 0xA0=GetRequest, 0xA1=GetNextRequest
        [string[]]$Oids,
        [int]$TimeoutMs = 2000
    )
    $udp = [System.Net.Sockets.UdpClient]::new()
    $udp.Client.ReceiveTimeout = $TimeoutMs
    $udp.Connect($TargetIp,161)
    try {
        $reqId = New-RequestId
        $varBinds = @()
        foreach ($oid in $Oids) { $varBinds += (New-SnmpVarBind $oid (ConvertTo-BerNull)) }
        $pdu = New-SnmpGetPdu $PduTag $reqId $varBinds
        $packet = New-SnmpV2CPacket $Community $pdu
        [void]$udp.Send($packet, $packet.Length)

        $remoteEP = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,0)
        $resp = $udp.Receive([ref]$remoteEP)
        return ,$resp
    } catch {
        return $null
    } finally {
        $udp.Close()
    }
}

# Basic BER helpers to parse enough for our needs (OID + value as string/integer)
function ConvertFrom-BerLength([byte[]]$data,[ref]$offset) {
    $lenByte = $data[$offset.Value]; $offset.Value++
    if (($lenByte -band 0x80) -eq 0) { return [int]$lenByte }
    $lenLen = $lenByte -band 0x7F
    $len = 0
    for ($i=0; $i -lt $lenLen; $i++) { $len = ($len -shl 8) -bor $data[$offset.Value]; $offset.Value++ }
    return $len
}

function ConvertFrom-BerOid([byte[]]$data,[ref]$offset,[int]$len) {
    $end = $offset.Value + $len
    $first = $data[$offset.Value]; $offset.Value++
    $oid0 = [int]([math]::Floor($first / 40))
    $oid1 = [int]($first % 40)
    $parts = @($oid0,$oid1)
    while ($offset.Value -lt $end) {
        $val = 0
        do {
            $b = $data[$offset.Value]; $offset.Value++
            $val = ($val -shl 7) -bor ($b -band 0x7F)
        } while (($b -band 0x80) -ne 0 -and $offset.Value -lt $end)
        $parts += $val
    }
    return ($parts -join '.')
}

function ConvertFrom-BerValue([byte[]]$data,[ref]$offset) {
    $tag = $data[$offset.Value]; $offset.Value++
    $len = ConvertFrom-BerLength $data ([ref]$offset)
    switch ($tag) {
        0x04 { # Octet String
            $bytes = $data[$offset.Value..($offset.Value+$len-1)]
            $offset.Value += $len
            return ,@("octet", [System.Text.Encoding]::ASCII.GetString($bytes))
        }
        0x02 { # Integer
            $val = 0
            for ($i=0; $i -lt $len; $i++) {
                $val = ($val -shl 8) -bor $data[$offset.Value+$i]
            }
            $offset.Value += $len
            return ,@("int", $val)
        }
        0x05 { # Null
            $offset.Value += $len
            return ,@("null", $null)
        }
        0x06 { # OID (rare as value)
            $oid = ConvertFrom-BerOid $data ([ref]$offset) $len
            return ,@("oid",$oid)
        }
        default {
            # Skip unknown type
            $offset.Value += $len
            return ,@("raw",$null)
        }
    }
}

function ConvertFrom-SnmpVarBinds([byte[]]$data) {
    # Minimal parse to reach VarBind list
    $off = 0
    if ($data[$off] -ne 0x30) { return @() }; $off++; $null = ConvertFrom-BerLength $data ([ref]$off)
    if ($data[$off] -ne 0x02) { return @() }; $off++; $len = ConvertFrom-BerLength $data ([ref]$off); $off += $len  # version
    if ($data[$off] -ne 0x04) { return @() }; $off++; $commLen = ConvertFrom-BerLength $data ([ref]$off); $off += $commLen
    # PDU (A2/response) -> skip header to varbinds
    $off++
    $null = ConvertFrom-BerLength $data ([ref]$off)
    # request-id, error-status, error-index
    if ($data[$off] -eq 0x02){ $off++; $len = ConvertFrom-BerLength $data ([ref]$off); $off += $len }
    if ($data[$off] -eq 0x02){ $off++; $len = ConvertFrom-BerLength $data ([ref]$off); $off += $len }
    if ($data[$off] -eq 0x02){ $off++; $len = ConvertFrom-BerLength $data ([ref]$off); $off += $len }
    # VarBindList
    if ($data[$off] -ne 0x30) { return @() }; $off++; $vblLen = ConvertFrom-BerLength $data ([ref]$off)
    $vblEnd = $off + $vblLen
    $out = @()
    while ($off -lt $vblEnd) {
        if ($data[$off] -ne 0x30) { break }; $off++; $vbLen = ConvertFrom-BerLength $data ([ref]$off)
        $vbEnd = $off + $vbLen
        # OID
        if ($data[$off] -ne 0x06) { break }; $off++; $oidLen = ConvertFrom-BerLength $data ([ref]$off)
        $oid = ConvertFrom-BerOid $data ([ref]$off) $oidLen
        # Value
        $type, $val = ConvertFrom-BerValue $data ([ref]$off)
        $out += [pscustomobject]@{ OID = $oid; Type = $type; Value = $val }
        $off = $vbEnd
    }
    return $out
}

# ---------------------------
# SNMP sysDescr.0
# ---------------------------
Write-Host "`nChecking SNMP UDP/161 (sysDescr.0)..." -ForegroundColor Yellow
$sysDescrOID = "1.3.6.1.2.1.1.1.0"
$resp = Invoke-SnmpRequest -TargetIp $ip -Community $community -PduTag 0xA0 -Oids @($sysDescrOID) -TimeoutMs 2000

if ($null -ne $resp -and $resp.Length -gt 0) {
    $vbs = ConvertFrom-SnmpVarBinds $resp
    $descr = ($vbs | Where-Object {$_.OID -eq $sysDescrOID} | Select-Object -First 1)
    if ($descr) {
        Write-Host "✅ SNMP response from $ip" -ForegroundColor Green
        Write-Host ("sysDescr.0: " + $descr.Value)
    } else {
        Write-Host "⚠️ SNMP responded, but sysDescr.0 not parsed (device-specific encoding?)." -ForegroundColor Yellow
    }
} else {
    Write-Host "❌ No SNMP response from $ip (UDP/161). Check ACLs, community, or SNMP service." -ForegroundColor Red
}

# ---------------------------
# Printer Supplies Walk (best-effort)
# ---------------------------
$descBase = "1.3.6.1.2.1.43.11.1.1.9"
$levelBase = "1.3.6.1.2.1.43.11.1.1.8"
$maxBase  = "1.3.6.1.2.1.43.11.1.1.7"

Write-Host "`nQuerying Printer-MIB supplies (best-effort walk)..." -ForegroundColor Yellow

function Get-SnmpWalkBaseOid {
    param(
        [string]$TargetIp,
        [string]$Community,
        [string]$BaseOID,
        [int]$MaxSteps = 40
    )
    $current = $BaseOID
    $results = @()
    for ($i=0; $i -lt $MaxSteps; $i++) {
        $resp = Invoke-SnmpRequest -TargetIp $TargetIp -Community $Community -PduTag 0xA1 -Oids @($current) -TimeoutMs 2000  # GET-NEXT
        if ($null -eq $resp) { break }
        $vbs = ConvertFrom-SnmpVarBinds $resp
        if ($vbs.Count -eq 0) { break }
        $vb = $vbs[0]
        if (-not $vb.OID.StartsWith($BaseOID + ".")) { break }
        $results += $vb
        $current = $vb.OID
    }
    return $results
}

$desc = Get-SnmpWalkBaseOid -TargetIp $ip -Community $community -BaseOID $descBase
$level = Get-SnmpWalkBaseOid -TargetIp $ip -Community $community -BaseOID $levelBase
$max   = Get-SnmpWalkBaseOid -TargetIp $ip -Community $community -BaseOID $maxBase

if ($desc.Count -eq 0 -and $level.Count -eq 0 -and $max.Count -eq 0) {
    Write-Host "⚠️ No Printer-MIB supplies entries returned. Device may restrict these OIDs or require a different community." -ForegroundColor Yellow
} else {
    # Join by trailing index
    $byIndex = @{}
    foreach ($d in $desc) {
        $idx = $d.OID.Substring($descBase.Length+1)
        $byIndex[$idx] = [ordered]@{ Description = $d.Value; Level = $null; Max = $null }
    }
    foreach ($l in $level) {
        $idx = $l.OID.Substring($levelBase.Length+1)
        if (-not $byIndex.ContainsKey($idx)) { $byIndex[$idx] = [ordered]@{ Description = $null; Level = $null; Max = $null } }
        $byIndex[$idx]["Level"] = $l.Value
    }
    foreach ($m in $max) {
        $idx = $m.OID.Substring($maxBase.Length+1)
        if (-not $byIndex.ContainsKey($idx)) { $byIndex[$idx] = [ordered]@{ Description = $null; Level = $null; Max = $null } }
        $byIndex[$idx]["Max"] = $m.Value
    }

    Write-Host "`nSupplies:" -ForegroundColor Cyan
    "{0,-6}  {1,-30}  {2,8}  {3,8}" -f "Index","Description","Level","Max"
    "{0,-6}  {1,-30}  {2,8}  {3,8}" -f "-----","-----------","-----","---"
    foreach ($k in ($byIndex.Keys | Sort-Object {[int]($_ -replace '\D','')})) {
        $row = $byIndex[$k]
        $pct = $null
        if ($row.Level -is [int] -and $row.Max -is [int] -and $row.Max -gt 0) {
            $pct = [math]::Round(($row.Level / $row.Max) * 100)
        }
        $descText = if ($row.Description) { [string]$row.Description } else { "(unknown)" }
        $lvlText  = if ($null -ne $row.Level) { $row.Level } else { "-" }
        $maxText  = if ($null -ne $row.Max) { $row.Max } else { "-" }
        $line = "{0,-6}  {1,-30}  {2,8}  {3,8}" -f $k, ($descText.Substring(0,[math]::Min(30,$descText.Length))), $lvlText, $maxText
        Write-Host $line
        if ($null -ne $pct) {
            Write-Host ("         -> ~{0}% remaining" -f $pct)
        }
    }
}

Write-Host "`n=== Test complete ===" -ForegroundColor Cyan