# ==============================================================================
#  Check Access Rule Hit Count and export as CSV
#  Author: Visual Wu
#  Date: 2025‑05‑19
# ==============================================================================

# ====== 忽略自簽憑證 ======
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

# ====== 登入 ======
$mgmtServer = Read-Host "請輸入 SMS IP (e.g. 10.0.1.100) [default 10.1.1.101]"
if ([string]::IsNullOrWhiteSpace($mgmtServer)) { $mgmtServer = '10.1.1.101' }
$mgmtUser   = Read-Host "請輸入管理帳號 [default admin]"
if ([string]::IsNullOrWhiteSpace($mgmtUser)) { $mgmtUser = 'admin' }
$securePwd  = Read-Host "請輸入管理密碼" -AsSecureString
$plainPwd   = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                 [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
$baseUrl    = "https://$mgmtServer/web_api"
$loginBody = @{ user = $mgmtUser; password = $plainPwd } | ConvertTo-Json
$loginResp = Invoke-RestMethod -Uri "$baseUrl/login" -Method Post `
                               -Body $loginBody -ContentType "application/json"
$headers   = @{ "X-chkp-sid" = $loginResp.sid }

# ====== 取得查詢時間範圍 ======
$startInput = Read-Host "請輸入查詢起始時間 (格式須為: YYYYMMDD) 或用 -DD 查詢過去 DD 日的資料"
if ($startInput.StartsWith('-')) {
    $days     = [int]$startInput.TrimStart('-')
    $toDate   = Get-Date
    $fromDate = $toDate.AddDays(-$days)
}
elseif ($startInput -match '^\d{8}$') {
    $fromDate = [datetime]::ParseExact($startInput, 'yyyyMMdd', $null)
    $endInput = Read-Host "請輸入查詢結束時間 (YYYYMMDD, default today)"
    if ([string]::IsNullOrWhiteSpace($endInput)) {
        $toDate = Get-Date
    }
    elseif ($endInput -match '^\d{8}$') {
        $toDate = [datetime]::ParseExact($endInput, 'yyyyMMdd', $null)
    }
    else {
        Write-Error "結束日期格式錯誤，須為YYYYMMDD (e.g. 20250101)"; exit
    }
}
else {
    Write-Error "起始日期格式錯誤，須為YYYYMMDD (e.g. 20250101)"; exit
}

$fromStr = $fromDate.ToString("yyyy-MM-dd")
$toStr   = $toDate.ToString("yyyy-MM-ddTHH:mm:ss")
Write-Host "查詢 $fromStr 到 $toStr 所有 gateways 的 hit count"

# ====== 選擇 Policy Package 與 Layer ======
$packages = Invoke-RestMethod -Uri "$baseUrl/show-packages" -Method Post `
                              -Headers $headers -Body '{}' -ContentType "application/json"
for ($i = 0; $i -lt $packages.packages.Count; $i++) {
    Write-Host "$i. $($packages.packages[$i].name)"
}
$choice      = Read-Host "選擇要查詢的 Package [default 0]"
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '0' }
$packageName = $packages.packages[$choice].name
$pkgResp = Invoke-RestMethod -Uri "$baseUrl/show-package" -Method Post `
                            -Headers $headers `
                            -Body (@{ name = $packageName }|ConvertTo-Json) `
                            -ContentType "application/json"
$layers   = $pkgResp."access-layers"

# ====== 遞迴擷取函式：取出 hits.value, source, destination 與 Service ======
$allRules = New-Object System.Collections.Generic.List[object]
function Extract-RulesWithHits {
    param($ruleList, $layerName)
    foreach ($r in $ruleList) {
        if ($r.type -eq "access-section" -and $r.rulebase) {
            Extract-RulesWithHits $r.rulebase $layerName; continue
        }
        if ($r.type -ne "access-rule") { continue }

        # source
        $srcList = if ($r.source -is [array]) { $r.source } else { ,$r.source }
        $sources = ($srcList |
            ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } } |
            Where-Object { $_ } |
            Sort-Object -Unique) -join ", "

        # destination
        $dstList = if ($r.destination -is [array]) { $r.destination } else { ,$r.destination }
        $destinations = ($dstList |
            ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } } |
            Where-Object { $_ } |
            Sort-Object -Unique) -join ", "

        # Service
        $svcList = if ($r.service -is [array]) { $r.service } else { ,$r.service }
        $services = ($svcList |
            ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } } |
            Where-Object { $_ } |
            Sort-Object -Unique) -join ", "

        # Hit Count
        $hit = 0
        if ($null -ne $r.hits -and $r.hits.value -ne $null) {
            $hit = $r.hits.value
        }
        elseif ($r.statistics -and $r.statistics.hits -and $r.statistics.hits.value -ne $null) {
            $hit = $r.statistics.hits.value
        }

        # output
        $allRules.Add([PSCustomObject]@{
            UID         = $r.uid
            Name        = $r.name
            Number      = $r.'rule-number'
            Layer       = $layerName
            Action      = if ($r.action -is [string]) { $r.action } else { $r.action.name }
            Enabled     = $r.enabled
            Source      = $sources
            Destination = $destinations
            Service     = $services
            HitCount    = $hit
        })
    }
}

# ====== 逐層呼叫 show-access-rulebase，帶入 hits-settings(from/to) ======
foreach ($layer in $layers) {
    Write-Host "`nScanning layer: $($layer.name)"
    $offset = 0; $limit = 500
    do {
        $body = @{
            name                    = $layer.name
            package                 = $packageName
            offset                  = $offset
            limit                   = $limit
            "details-level"         = "full"
            "use-object-dictionary" = $false
            "show-hits"             = $true
            "hits-settings"         = @{
                                          "from-date" = $fromStr
                                          "to-date"   = $toStr
                                       }
        } | ConvertTo-Json -Depth 20

        $resp = Invoke-RestMethod -Uri "$baseUrl/show-access-rulebase" `
                                  -Method Post `
                                  -Headers $headers `
                                  -Body $body `
                                  -ContentType "application/json"

        Extract-RulesWithHits $resp.rulebase $layer.name
        $offset += $limit
    } while ($resp.total -gt $offset)
}

# ====== export ======
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$exportDir = "$PSScriptRoot\Rules_Hits_$timestamp"
New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
$allRules | Export-Csv "$exportDir\all_rules_hits_$timestamp.csv" -NoTypeInformation -Encoding UTF8
Write-Host "`nExport: $exportDir`n"

# ======  logout ======
Invoke-RestMethod -Uri "$baseUrl/logout" -Method Post `
                  -Headers $headers -Body '{}' -ContentType "application/json" | Out-Null