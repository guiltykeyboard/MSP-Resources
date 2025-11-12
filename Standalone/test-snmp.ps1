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
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)


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
function Get-LocalIPv4Context {
    param([string]$DestinationIp)
    # Helpers
    function Convert-IPStringToBytes([string]$ip) {
        return ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
    }
    function Convert-BytesToIPString([byte[]]$bytes) {
        return ([System.Net.IPAddress]::new($bytes)).ToString()
    }
    function Get-NetworkAddress([string]$ip,[int]$prefix) {
        $bytes = Convert-IPStringToBytes $ip
        $mask = [byte[]](0,0,0,0)
        for ($i=0; $i -lt 4; $i++) {
            $bits = [Math]::Max([Math]::Min($prefix - ($i*8), 8), 0)
            $mask[$i] = [byte](0xFF -shl (8 - $bits) -band 0xFF)
        }
        $net = [byte[]](0,0,0,0)
        for ($i=0; $i -lt 4; $i++) { $net[$i] = [byte]($bytes[$i] -band $mask[$i]) }
        return Convert-BytesToIPString $net
    }
    function Get-NetworkCIDR([string]$ip,[int]$prefix) {
        return ("{0}/{1}" -f (Get-NetworkAddress $ip $prefix), $prefix)
    }

    try {
        $route = Get-NetRoute -DestinationPrefix "$DestinationIp/32" -AddressFamily IPv4 -ErrorAction Stop |
                 Sort-Object RouteMetric, PrefSource -Descending:$false | Select-Object -First 1
        if ($null -ne $route) {
            $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 |
                    Where-Object { $null -ne $_.IPAddress -and $_.SkipAsSource -ne $true } |
                    Sort-Object -Property PrefixLength -Descending:$true | Select-Object -First 1
            if ($addr) {
                $cidr = "{0}/{1}" -f $addr.IPAddress, $addr.PrefixLength
                $netCidr = Get-NetworkCIDR $addr.IPAddress $addr.PrefixLength
                $ifAlias = (Get-NetIPInterface -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4).InterfaceAlias
                return [pscustomobject]@{
                    IPAddress    = $addr.IPAddress
                    PrefixLength = $addr.PrefixLength
                    CIDR         = $cidr
                    NetworkCIDR  = $netCidr
                    Gateway      = $route.NextHop
                    InterfaceAlias = $ifAlias
                }
            }
        }
    } catch { }
    # Fallback: primary interface with default gateway
    $primary = Get-NetIPConfiguration | Where-Object { $null -ne $_.IPv4DefaultGateway } | Select-Object -First 1
    if ($primary -and $primary.IPv4Address -and $primary.IPv4Address.IPAddress) {
        $ipAddr = $primary.IPv4Address.IPAddress
        $pl = ($primary.IPv4Address | Select-Object -First 1).PrefixLength
        return [pscustomobject]@{
            IPAddress    = $ipAddr
            PrefixLength = $pl
            CIDR         = ("{0}/{1}" -f $ipAddr, $pl)
            NetworkCIDR  = (Get-NetworkCIDR $ipAddr $pl)
            Gateway      = $primary.IPv4DefaultGateway.NextHop
            InterfaceAlias = $primary.InterfaceAlias
        }
    }
    return [pscustomobject]@{
        IPAddress    = $null
        PrefixLength = $null
        CIDR         = "(unknown)"
        NetworkCIDR  = "(unknown)"
        Gateway      = "(unknown)"
        InterfaceAlias = "(unknown)"
    }
}

$local = Get-LocalIPv4Context -DestinationIp $ip
Write-Host ("Local endpoint for this test: {0}" -f $local.CIDR) -ForegroundColor DarkCyan
Write-Host ("Local network: {0}" -f $local.NetworkCIDR) -ForegroundColor DarkCyan
Write-Host ("Gateway: {0} (Interface: {1})" -f $local.Gateway, $local.InterfaceAlias) -ForegroundColor DarkCyan

# ---------------------------
# TCP 443 Reachability Test
# ---------------------------
Write-Host "`n=== Connectivity test to $ip ===" -ForegroundColor Cyan
Write-Host "Checking TCP port 443 (HTTPS)..." -ForegroundColor Yellow
$tcp = Test-NetConnection -ComputerName $ip -Port 443 -WarningAction SilentlyContinue
if ($tcp.TcpTestSucceeded) {
    Write-Host "[OK] TCP 443 reachable on $ip" -ForegroundColor Green
} else {
    Write-Host "[FAIL] TCP 443 NOT reachable on $ip" -ForegroundColor Red
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
        if ( ($value -ge 0 -and ($msb -band 0x80) -ne 0) -or ($value -lt 0 -and ($msb -band 0x80) -eq 0) ) {
            if ($value -lt 0) {
                $tmp.Add([byte]0xFF)
            } else {
                $tmp.Add([byte]0x00)
            }
        }
        $tmpArr = $tmp.ToArray()
        [Array]::Reverse($tmpArr)
        $tmp = [System.Collections.Generic.List[byte]]::new()
        $tmp.AddRange($tmpArr)
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
# Helper: Build a Xerox‑safe SNMPv2c GET for a single OID
# (explicit ASN.1/BER with short-length forms where applicable)
# ---------------------------
# ---------------------------
# Helper: Build a Xerox‑safe SNMPv2c GET for a single OID
# (explicit ASN.1/BER with short-length forms where applicable)
# ---------------------------
function New-SnmpV2cGetPacketSimple {
    param(
        [Parameter(Mandatory=$true)][string]$Community,
        [Parameter(Mandatory=$true)][string]$Oid,
        [Parameter(Mandatory=$true)][int]$RequestId
    )
    # Encode version (v2c = 1)
    $ver    = ,0x02 + ,0x01 + ,0x01
    # Encode community (ASCII, no BOM)
    $cbytes = [System.Text.Encoding]::GetEncoding("us-ascii").GetBytes($Community)
    $comm   = ,0x04 + ,([byte]$cbytes.Length) + $cbytes
    # Encode OID
    function _EncodeOid([string]$oid) {
        $parts = $oid.Split('.') | ForEach-Object {[uint32]$_}
        $first = [byte]($parts[0]*40 + $parts[1])
        $body  = New-Object System.Collections.Generic.List[byte]
        $body.Add($first) | Out-Null
        for ($i=2; $i -lt $parts.Length; $i++) {
            $v = [uint32]$parts[$i]
            $stack = New-Object System.Collections.Generic.List[byte]
            $stack.Add([byte]($v -band 0x7F)) | Out-Null
            $v = $v -shr 7
            while ($v -gt 0) { $stack.Add([byte](0x80 -bor ($v -band 0x7F))) | Out-Null; $v = $v -shr 7 }
            $arr = $stack.ToArray(); [Array]::Reverse($arr)
            $body.AddRange($arr)
        }
        $content = $body.ToArray()
        return ,0x06 + ,([byte]$content.Length) + $content
    }
    # Helper to encode positive INTEGER in fixed 4-byte big-endian form
    function _EncIntPosFixed4([int]$v) {
        if ($v -lt 0) { throw "RequestId must be non-negative" }
        $b0 = [byte](($v -shr 24) -band 0xFF)
        $b1 = [byte](($v -shr 16) -band 0xFF)
        $b2 = [byte](($v -shr 8)  -band 0xFF)
        $b3 = [byte]($v -band 0xFF)
        return ,0x02 + ,0x04 + ,$b0 + ,$b1 + ,$b2 + ,$b3
    }
    # INTEGER encoder (positive only for our fields)
    function _EncInt([int]$v) {
        if ($v -lt 0) { throw "RequestId must be non-negative" }
        if ($v -lt 0x80) { return ,0x02 + ,0x01 + ,([byte]$v) }
        $tmp = New-Object System.Collections.Generic.List[byte]
        $n = $v
        while ($n -gt 0) { $tmp.Add([byte]($n -band 0xFF)); $n = $n -shr 8 }
        $arr = $tmp.ToArray(); [Array]::Reverse($arr)
        if (($arr[0] -band 0x80) -ne 0) { $arr = ,0x00 + $arr } # ensure positive sign
        return ,0x02 + ,([byte]$arr.Length) + $arr
    }
    # VarBind: OID + NULL
    $vb = (_EncodeOid $Oid) + ,0x05 + ,0x00
    $vbl = ,0x30 + ,([byte]$vb.Length) + $vb
    # PDU: GetRequest (0xA0) :: request-id, error-status=0, error-index=0, varbindlist
    $pduCore = (_EncIntPosFixed4 $RequestId) + (_EncInt 0) + (_EncInt 0) + $vbl
    $pdu     = ,0xA0 + ,([byte]$pduCore.Length) + $pduCore
    # Message: SEQUENCE(version, community, pdu)
    $msgCore = $ver + $comm + $pdu
    return ,0x30 + ,([byte]$msgCore.Length) + $msgCore
}

# ---------------------------
# Helper: Build a Xerox‑safe SNMPv2c GET-NEXT for a single OID
# ---------------------------
function New-SnmpV2cGetNextPacketSimple {
    param(
        [Parameter(Mandatory=$true)][string]$Community,
        [Parameter(Mandatory=$true)][string]$Oid,
        [Parameter(Mandatory=$true)][int]$RequestId
    )
    # version (v2c = 1)
    $ver    = ,0x02 + ,0x01 + ,0x01
    # community (ASCII, no BOM)
    $cbytes = [System.Text.Encoding]::GetEncoding("us-ascii").GetBytes($Community)
    $comm   = ,0x04 + ,([byte]$cbytes.Length) + $cbytes
    # OID encoder
    function _EncodeOid([string]$oid) {
        $parts = $oid.Split('.') | ForEach-Object {[uint32]$_}
        $first = [byte]($parts[0]*40 + $parts[1])
        $body  = New-Object System.Collections.Generic.List[byte]
        $body.Add($first) | Out-Null
        for ($i=2; $i -lt $parts.Length; $i++) {
            $v = [uint32]$parts[$i]
            $stack = New-Object System.Collections.Generic.List[byte]
            $stack.Add([byte]($v -band 0x7F)) | Out-Null
            $v = $v -shr 7
            while ($v -gt 0) { $stack.Add([byte](0x80 -bor ($v -band 0x7F))) | Out-Null; $v = $v -shr 7 }
            $arr = $stack.ToArray(); [Array]::Reverse($arr)
            $body.AddRange($arr)
        }
        $content = $body.ToArray()
        return ,0x06 + ,([byte]$content.Length) + $content
    }
    # Helper to encode positive INTEGER in fixed 4-byte big-endian form
    function _EncIntPosFixed4([int]$v) {
        if ($v -lt 0) { throw "RequestId must be non-negative" }
        $b0 = [byte](($v -shr 24) -band 0xFF)
        $b1 = [byte](($v -shr 16) -band 0xFF)
        $b2 = [byte](($v -shr 8)  -band 0xFF)
        $b3 = [byte]($v -band 0xFF)
        return ,0x02 + ,0x04 + ,$b0 + ,$b1 + ,$b2 + ,$b3
    }
    # INTEGER encoder (positive)
    function _EncInt([int]$v) {
        if ($v -lt 0) { throw "RequestId must be non-negative" }
        if ($v -lt 0x80) { return ,0x02 + ,0x01 + ,([byte]$v) }
        $tmp = New-Object System.Collections.Generic.List[byte]
        $n = $v
        while ($n -gt 0) { $tmp.Add([byte]($n -band 0xFF)); $n = $n -shr 8 }
        $arr = $tmp.ToArray(); [Array]::Reverse($arr)
        if (($arr[0] -band 0x80) -ne 0) { $arr = ,0x00 + $arr }
        return ,0x02 + ,([byte]$arr.Length) + $arr
    }
    # VarBind: OID + NULL
    $vb = (_EncodeOid $Oid) + ,0x05 + ,0x00
    $vbl = ,0x30 + ,([byte]$vb.Length) + $vb
    # PDU: GetNextRequest (0xA1)
    $pduCore = (_EncIntPosFixed4 $RequestId) + (_EncInt 0) + (_EncInt 0) + $vbl
    $pdu     = ,0xA1 + ,([byte]$pduCore.Length) + $pduCore
    # Message: SEQUENCE(version, community, pdu)
    $msgCore = $ver + $comm + $pdu
    return ,0x30 + ,([byte]$msgCore.Length) + $msgCore
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
        [int]$TimeoutMs = 6000
    )
    # Bind to the same local IPv4 used for routing to the target (if known)
    $bindIp = $null
    try {
        if ($script:local -and $script:local.IPAddress) { $bindIp = $script:local.IPAddress }
    } catch {}
    if ($bindIp) {
        $localEp = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($bindIp), 0)
        $udp = [System.Net.Sockets.UdpClient]::new($localEp)
    } else {
        $udp = [System.Net.Sockets.UdpClient]::new([System.Net.Sockets.AddressFamily]::InterNetwork)
    }
    $udp.Client.ReceiveTimeout = $TimeoutMs
    $udp.Client.SendBufferSize = 4096
    $udp.Client.ReceiveBufferSize = 4096
    $udp.Connect($TargetIp, 161)

    # Build packet (strict simple encoder for Xerox)
    $reqId = Get-Random -Minimum 1 -Maximum 32767
    if ($Oids.Count -ne 1) { throw "Invoke-SnmpRequest expects exactly one OID in this build." }
    if ($PduTag -eq 0xA0) {
        $packet = New-SnmpV2cGetPacketSimple -Community $Community -Oid $Oids[0] -RequestId $reqId
    } elseif ($PduTag -eq 0xA1) {
        $packet = New-SnmpV2cGetNextPacketSimple -Community $Community -Oid $Oids[0] -RequestId $reqId
    } else {
        throw "Unsupported PDU tag: $PduTag"
    }

    # Optional debug hexdump
    $debug = $env:SNMP_DEBUG -eq '1'
    if ($debug) {
        $hex = ($packet | ForEach-Object { $_.ToString('X2') }) -join ' '
        Write-Host ("[DBG] SNMP TX ({0} bytes): {1}" -f $packet.Length, $hex) -ForegroundColor DarkGray
    }

    # Send with retries
    $attempts = 3
    for ($i=1; $i -le $attempts; $i++) {
        try {
            [void]$udp.Send($packet, $packet.Length)
            $remoteEP = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $resp = $udp.Receive([ref]$remoteEP)
            if ($debug -and $resp) {
                $hexr = ($resp | ForEach-Object { $_.ToString('X2') }) -join ' '
                Write-Host ("[DBG] SNMP RX ({0} bytes): {1}" -f $resp.Length, $hexr) -ForegroundColor DarkGray
            }
            $udp.Close()
            return ,$resp
        } catch {
            if ($i -lt $attempts) { Start-Sleep -Milliseconds 300; continue }
            $udp.Close()
            return $null
        }
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
# Helper: Test-IsSameSubnet
# ---------------------------
function Test-IsSameSubnet {
    param(
        [string]$LocalIp,
        [int]$LocalPrefix,
        [string]$TargetIp
    )
    function ToBytes([string]$x){ ([System.Net.IPAddress]::Parse($x)).GetAddressBytes() }
    $lip = ToBytes $LocalIp
    $tip = ToBytes $TargetIp
    $mask = [byte[]](0,0,0,0)
    for ($i=0; $i -lt 4; $i++) {
        $bits = [Math]::Max([Math]::Min($LocalPrefix - ($i*8), 8), 0)
        $mask[$i] = [byte](0xFF -shl (8 - $bits) -band 0xFF)
    }
    for ($i=0; $i -lt 4; $i++) {
        if ( ($lip[$i] -band $mask[$i]) -ne ($tip[$i] -band $mask[$i]) ) { return $false }
    }
    return $true
}

 # ---------------------------
# Helper: Identify possible Windows Firewall blocks for SNMP
# ---------------------------
function Get-PossibleFirewallBlocksForSnmp {
    param(
        [string]$TargetIp
    )
    $results = @()


    function RuleMatchesTarget {
        param($rule,$pf,$af,[string]$dir)
        # Protocol match (UDP or Any)
        $protoOk = ($pf.Protocol -eq 'UDP' -or $pf.Protocol -eq 'Any' -or $pf.Protocol -eq 17 -or $pf.Protocol -eq 256)
        if (-not $protoOk) { return $false }

        # Ports
        $remotePort = [string]$pf.RemotePort
        $localPort  = [string]$pf.LocalPort
        $remotePortAny = [string]::IsNullOrEmpty($remotePort) -or $remotePort -eq 'Any' -or $remotePort -eq '*'
        $localPortAny  = [string]::IsNullOrEmpty($localPort)  -or $localPort  -eq 'Any' -or $localPort  -eq '*'

        $portOk = $false
        if ($dir -eq 'Outbound') {
            $portOk = ($remotePortAny -or ($remotePort -match '(^|,|\s)161($|,|\s)'))
        } else {
            # inbound response will be FROM remote port 161 TO local ephemeral port.
            $portOk = ($remotePortAny -or ($remotePort -match '(^|,|\s)161($|,|\s)') -or $localPortAny)
        }
        if (-not $portOk) { return $false }

        # Address filter
        $remoteAddr = $af.RemoteAddress
        $addrOk = $false
        if (-not $remoteAddr -or $remoteAddr -eq 'Any' -or $remoteAddr -eq '*') { $addrOk = $true }
        else {
            # RemoteAddress can be a list; do simple contains/equals
            if ($remoteAddr -is [array]) { $addrOk = $remoteAddr -contains $TargetIp }
            else { $addrOk = ($remoteAddr -eq $TargetIp) }
        }
        return $addrOk
    }

    # Outbound BLOCK rules that could block UDP/161 to target
    try {
        $outBlock = Get-NetFirewallRule -Enabled True -Direction Outbound -Action Block -ErrorAction SilentlyContinue
        foreach ($r in $outBlock) {
            $pf = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $r
            $af = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $r
            if ($pf -and (RuleMatchesTarget -rule $r -pf $pf -af $af -dir 'Outbound')) {
                $results += [pscustomobject]@{
                    Direction   = 'Outbound'
                    Name        = $r.Name
                    DisplayName = $r.DisplayName
                    Profile     = $r.Profile
                    Protocol    = $pf.Protocol
                    LocalPort   = $pf.LocalPort
                    RemotePort  = $pf.RemotePort
                    RemoteAddr  = $af.RemoteAddress
                    Action      = $r.Action
                }
            }
        }
    } catch {}

    # Inbound BLOCK rules that could block UDP responses from remote port 161
    try {
        $inBlock = Get-NetFirewallRule -Enabled True -Direction Inbound -Action Block -ErrorAction SilentlyContinue
        foreach ($r in $inBlock) {
            $pf = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $r
            $af = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $r
            if ($pf -and (RuleMatchesTarget -rule $r -pf $pf -af $af -dir 'Inbound')) {
                $results += [pscustomobject]@{
                    Direction   = 'Inbound'
                    Name        = $r.Name
                    DisplayName = $r.DisplayName
                    Profile     = $r.Profile
                    Protocol    = $pf.Protocol
                    LocalPort   = $pf.LocalPort
                    RemotePort  = $pf.RemotePort
                    RemoteAddr  = $af.RemoteAddress
                    Action      = $r.Action
                }
            }
        }
    } catch {}

    return $results
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
        Write-Host "[OK] SNMP response from $ip" -ForegroundColor Green
        Write-Host ("sysDescr.0: " + $descr.Value)
    } else {
        Write-Host "[WARN] SNMP responded, but sysDescr.0 not parsed (device-specific encoding?)." -ForegroundColor Yellow
    }
} else {
    $sameSubnet = $false
    if ($local -and $local.IPAddress -and $local.PrefixLength) {
        $sameSubnet = Test-IsSameSubnet -LocalIp $local.IPAddress -LocalPrefix $local.PrefixLength -TargetIp $ip
    }
    if (-not $sameSubnet) {
        Write-Host "[FAIL] Unable to communicate with printer using SNMP on UDP/161." -ForegroundColor Red
        Write-Host ("Reason hint: target {0} is on a DIFFERENT subnet than this computer." -f $ip)
        Write-Host ("Action: Printer technician should contact the network administrator to verify that SNMP (UDP/161) from monitoring computer {0} to target printer {1}/32 is allowed across the network boundary and is not blocked by a firewall rule/ACL." -f $local.CIDR, "$ip")
    } else {
        Write-Host "[FAIL] Target printer is on the SAME subnet, but SNMP (UDP/161) did not respond." -ForegroundColor Red
        Write-Host ("Action: Check whether SNMP is disabled on the printer via https://{0} . If SNMP is enabled, contact the network administrator to verify SNMP communication on the layer-2 network between {1} and {0}." -f $ip, $local.IPAddress)
    }
    # Inspect Windows Firewall for potential blocks
    try {
        $fwBlocks = Get-PossibleFirewallBlocksForSnmp -TargetIp $ip
        if ($fwBlocks -and $fwBlocks.Count -gt 0) {
            Write-Host "`n[FIREWALL] Windows Firewall appears to have rule(s) that may block SNMP (UDP/161) to this target:" -ForegroundColor Red
            $fwBlocks | ForEach-Object {
                Write-Host (" - {0} [{1}]  Proto={2}  LPort={3}  RPort={4}  RAddr={5}" -f $_.DisplayName, $_.Direction, $_.Protocol, $_.LocalPort, $_.RemotePort, ($_.RemoteAddr -join ',')) -ForegroundColor Red
            }
            Write-Host "[NOTE] This script does not modify firewall settings; list above is for triage only." -ForegroundColor Red
        } else {
            Write-Host "[OK] Windows Firewall does not appear to be blocking UDP/161 to this target." -ForegroundColor Green
        }
    } catch {
        Write-Host "[INFO] Skipped firewall inspection (insufficient privileges or cmdlets unavailable)." -ForegroundColor DarkGray
    }
}

# ---------------------------
# Quick helpers to read first value under a base OID (GET-NEXT)
# ---------------------------
function Get-SnmpFirstUnder {
    param(
        [string]$TargetIp,
        [string]$Community,
        [string]$BaseOid,
        [int]$TimeoutMs = 2000
    )
    $resp = Invoke-SnmpRequest -TargetIp $TargetIp -Community $Community -PduTag 0xA1 -Oids @($BaseOid) -TimeoutMs $TimeoutMs  # GET-NEXT
    if ($null -eq $resp) { return $null }
    $vbs = ConvertFrom-SnmpVarBinds $resp
    if ($vbs.Count -eq 0) { return $null }
    $vb = $vbs[0]
    if ($vb.OID -and $vb.OID.StartsWith($BaseOid + ".")) { return $vb }
    return $null
}

# ---------------------------
# Quick Device Info (name / serial / page count)
# ---------------------------
Write-Host "`nQuick device info (best-effort)..." -ForegroundColor Yellow

# sysName.0 (1.3.6.1.2.1.1.5.0) – standard SNMPv2-MIB
$sysNameOID = "1.3.6.1.2.1.1.5.0"
$sysNameResp = Invoke-SnmpRequest -TargetIp $ip -Community $community -PduTag 0xA0 -Oids @($sysNameOID) -TimeoutMs 1500
if ($sysNameResp) {
    $nvb = ConvertFrom-SnmpVarBinds $sysNameResp | Where-Object {$_.OID -eq $sysNameOID} | Select-Object -First 1
    if ($nvb -and $nvb.Value) {
        Write-Host (" - sysName.0: {0}" -f $nvb.Value)
    }
}

# prtGeneralSerialNumber (1.3.6.1.2.1.43.5.1.1.17.*) – table; grab first row via GET-NEXT on the column base
$serialBase = "1.3.6.1.2.1.43.5.1.1.17"
$serialVb = Get-SnmpFirstUnder -TargetIp $ip -Community $community -BaseOid $serialBase -TimeoutMs 1500
if ($serialVb -and $serialVb.Value) {
    Write-Host (" - SerialNumber: {0}  (OID {1})" -f $serialVb.Value, $serialVb.OID)
}

# prtMarkerLifeCount (1.3.6.1.2.1.43.10.2.1.4.*) – total page count style counter; first row via GET-NEXT
$pageCountBase = "1.3.6.1.2.1.43.10.2.1.4"
$pageVb = Get-SnmpFirstUnder -TargetIp $ip -Community $community -BaseOid $pageCountBase -TimeoutMs 1500
if ($pageVb -and $null -ne $pageVb.Value) {
    Write-Host (" - TotalPageCounter (prtMarkerLifeCount): {0}  (OID {1})" -f $pageVb.Value, $pageVb.OID)
}
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
    Write-Host "[WARN] No Printer-MIB supplies entries returned. Device may restrict these OIDs or require a different community." -ForegroundColor Yellow
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

# ---------------------------
# Summary for ticket notes (single line, easy to paste)
# ---------------------------
try {
    $httpsStatus = if ($tcp -and $tcp.TcpTestSucceeded) { 'PASS' } else { 'FAIL' }
} catch { $httpsStatus = 'UNKNOWN' }
try {
    $snmpStatus = if ($resp -and ($resp.Length -gt 0)) { 'PASS' } else { 'FAIL' }
} catch { $snmpStatus = 'UNKNOWN' }
try {
    $subnetRel = if ($local -and $local.IPAddress -and $local.PrefixLength -and $ip) {
        if (Test-IsSameSubnet -LocalIp $local.IPAddress -LocalPrefix $local.PrefixLength -TargetIp $ip) { 'same-subnet' } else { 'diff-subnet' }
    } else { 'subnet-unknown' }
} catch { $subnetRel = 'subnet-unknown' }

$pathInfo = if ($local) { "{0} via {1} ({2})" -f $local.CIDR, $local.Gateway, $local.InterfaceAlias } else { "(path unknown)" }
$summary = "SUMMARY: Target=$ip | HTTPS(443)=$httpsStatus | SNMP(161)=$snmpStatus | Scope=$subnetRel | From=$pathInfo"
Write-Host "`n$summary"

Write-Host "`n=== Test complete ===" -ForegroundColor Cyan