# ==============================================================================
#  List Disabled / Expired / Expiring‑Soon Rules in R82 Management via Web API
#  Author: Visual Wu
#  Date: 2025‑05‑02
# ==============================================================================

# ====== Ignore self‑signed certificates ======
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# ====== Login parameters ======
$mgmtServer = Read-Host "Enter SMS IP (e.g. 10.0.1.100)"
if ([string]::IsNullOrWhiteSpace($mgmtServer)) { $mgmtServer = '10.1.1.101' }
$mgmtUser   = Read-Host "Enter Username [admin]"
if ([string]::IsNullOrWhiteSpace($mgmtUser)) { $mgmtUser = 'admin' }
$securePwd  = Read-Host "Enter Password" -AsSecureString
$plainPwd   = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
$baseUrl    = "https://$mgmtServer/web_api"

# ====== Login ======
$loginBody = @{ user = $mgmtUser; password = $plainPwd } | ConvertTo-Json
$loginResp = Invoke-RestMethod -Uri "$baseUrl/login" -Method Post `
                               -Body $loginBody -ContentType "application/json"
$headers   = @{ "X-chkp-sid" = $loginResp.sid }

# ====== Ask days for “expiring soon” ======
$daysInput = Read-Host "Enter days to treat as 'expiring soon' [30]"
$days      = if ([string]::IsNullOrWhiteSpace($daysInput)) { 30 } else { [int]$daysInput }
Write-Host "Rules ending within $days days will be marked as 'Expiring soon'."

$now     = Get-Date
$inXDays = $now.AddDays($days)

# ====== Collect Time objects ======
Write-Host "`nRetrieving all time objects..."
$timeObjects = @{}   # uid --> [datetime] end
$timeNames   = @{}   # uid --> name

$offset = 0
do {
    $body = @{ type = "time"; limit = 50; offset = $offset } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$baseUrl/show-objects" -Method Post `
                               -Headers $headers -Body $body -ContentType "application/json"

    foreach ($obj in $resp.objects) {
        $detail = Invoke-RestMethod -Uri "$baseUrl/show-time" -Method Post `
                                    -Headers $headers `
                                    -Body (@{
                                            uid             = $obj.uid
                                            "details-level" = "full"
                                           } | ConvertTo-Json) `
                                    -ContentType "application/json"

        $timeNames[$detail.uid] = $detail.name

        $endStruct = $null
        $endStruct = $detail.end

        if ($endStruct) {
            if ($endStruct.'iso-8601') {
                $dt = [datetime]::Parse($endStruct.'iso-8601')
            } elseif ($endStruct.posix) {
                $epoch = [datetime]'1970-01-01T00:00:00Z'
                $dt    = $epoch.AddMilliseconds([double]$endStruct.posix).ToLocalTime()
            }
            if ($dt) { $timeObjects[$detail.uid] = $dt }
        }
    }
    $offset += $resp.objects.Count
} while ($resp.total -gt $offset)

# ====== Choose package ======
$packages = Invoke-RestMethod -Uri "$baseUrl/show-packages" -Method Post `
                              -Headers $headers -Body '{}' -ContentType "application/json"
for ($i = 0; $i -lt $packages.packages.Count; $i++) {
    Write-Host "$i. $($packages.packages[$i].name)"
}
$choice      = Read-Host "Enter the number of the desired package [0]"
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '0' }
$packageName = $packages.packages[$choice].name
$packageResp = Invoke-RestMethod -Uri "$baseUrl/show-package" -Method Post `
                                 -Headers $headers `
                                 -Body (@{ name = $packageName } | ConvertTo-Json) `
                                 -ContentType "application/json"
$layers      = $packageResp."access-layers"

# ====== Containers ======
$allRules         = New-Object System.Collections.Generic.List[object]
$disabledRules    = New-Object System.Collections.Generic.List[object]
$expiredRules     = New-Object System.Collections.Generic.List[object]
$expiringSoonList = New-Object System.Collections.Generic.List[object]

function Extract-Rules($ruleList, $layerName) {
    foreach ($r in $ruleList) {
        if ($r.type -eq "access-section" -and $r.rulebase) { Extract-Rules $r.rulebase $layerName; continue }
        if ($r.type -ne "access-rule") { continue }

        $ruleTimes = switch ($r.time) {
            { $_ -is [array] } { $_ }
            { $_ }             { ,$_ }
            default            { @() }
        }

        # Write-Host "`nRule: [$($r.name)]"
        # Write-Host "  Time Objects:"

        $expirationStatus = "none"

        foreach ($t in $ruleTimes) {
            $uid   = if ($t -is [string]) { $t } else { $t.uid }
            $tName = if ($timeNames.ContainsKey($uid)) { $timeNames[$uid] }
                     elseif ($t -is [string])          { $t }
                     else                              { $t.name }

            if ($uid -and $timeObjects.ContainsKey($uid)) {
                $validUntil = $timeObjects[$uid]
                # Write-Host "    $tName => $validUntil"
                if     ($validUntil -lt $now)                            { $expirationStatus = "expired" }
                elseif ($validUntil -le $inXDays -and $expirationStatus -ne "expired") {
                    $expirationStatus = "soon"
                }
            }
            else {
                # Write-Host "    $tName (no end date or not found)"
            }
        }

        $entry = [PSCustomObject]@{
            UID      = $r.uid
            Name     = $r.name
            Comment  = $r.comments
            Number   = $r.'rule-number'
            Layer    = $layerName
            Action   = if ($r.action -is [string]) { $r.action } else { $r.action.name }
            Enabled  = $r.enabled
            TimeObjs = ($ruleTimes | ForEach-Object {
                            if ($_ -is [string]) { $_ } else { $_.name }
                        } | Where-Object { $_ } | Sort-Object -Unique) -join ", "
        }

        $allRules.Add($entry)
        if     (-not $r.enabled)                   { $disabledRules.Add($entry) }
        elseif ($expirationStatus -eq "expired")   { $expiredRules.Add($entry) }
        elseif ($expirationStatus -eq "soon")      { $expiringSoonList.Add($entry) }
    }
}

# ====== Scan layers ======
foreach ($layer in $layers) {
    Write-Host "`nScanning layer: $($layer.name)"
    $offset = 0
    $limit  = 500
    do {
        $body = @{
            name            = $layer.name
            offset          = $offset
            limit           = $limit
            "details-level" = "full"
            "use-object-dictionary" = $false
        } | ConvertTo-Json -Depth 10

        $resp = Invoke-RestMethod -Uri "$baseUrl/show-access-rulebase" -Method Post `
                                   -Headers $headers -Body $body -ContentType "application/json"
        Extract-Rules $resp.rulebase $layer.name
        $offset += $limit
    } while ($resp.total -gt $offset)
}

# ====== Output summary & CSV ======
Write-Host "`nTotal rules found: $($allRules.Count)"
Write-Host "Disabled: $($disabledRules.Count) | Expired: $($expiredRules.Count) | Expiring in $days days: $($expiringSoonList.Count)"

$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$exportPath = "$PSScriptRoot\CheckRules_WebAPI_$timestamp"
New-Item -ItemType Directory -Path $exportPath -Force | Out-Null

$allRules         | Export-Csv "$exportPath\all_rules.csv"           -NoTypeInformation -Encoding UTF8
$disabledRules    | Export-Csv "$exportPath\disabled_rules.csv"      -NoTypeInformation -Encoding UTF8
$expiredRules     | Export-Csv "$exportPath\expired_rules.csv"       -NoTypeInformation -Encoding UTF8
$expiringSoonList | Export-Csv "$exportPath\expiring_soon_rules.csv" -NoTypeInformation -Encoding UTF8

Write-Host "`nExport complete: $exportPath"

# ====== Logout ======
Invoke-RestMethod -Uri "$baseUrl/logout" -Method Post -Headers $headers `
                  -Body '{}' -ContentType "application/json" | Out-Null
