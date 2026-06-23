<#
  update_market.ps1 — Монголбанк (FX) + (сонголтоор) МХБ-ийн датаг татаж live_extra.json бичих
  -----------------------------------------------------------------------------------------
  ЯАГААД server талд татах вэ:
    Монголбанк/МХБ нь CORS header ӨГДӨГГҮЙ тул dashboard-ийн браузер ШУУД татаж ЧАДАХГҮЙ.
    Энэ скрипт серверээс (CORS хамаагүй) татаад, dashboard-ийн ХАЖУУД live_extra.json үлдээнэ.
    Дараа nso_live.js үүнийг same-origin-оор уншина.

  АЖИЛЛУУЛАХ:
    .\update_market.ps1                       # одоогийн хавтсанд live_extra.json бичнэ
    .\update_market.ps1 -OutPath C:\www\app   # тухайн (dashboard байрлах) хавтсанд бичнэ
  ХУВААРЬТ (Task Scheduler) 30 мин тутам:
    schtasks /create /tn "MarketFX" /tr "powershell -File D:\...\update_market.ps1 -OutPath C:\www\app" /sc minute /mo 30
#>
param(
  [string]$OutPath = ".",
  [int]$Days = 45,           # FX түүхийн хоног (график үүсгэхэд)
  # Гар тохиргоо (нийтийн live API байхгүй, ховор өөрчлөгддөг):
  [double]$PolicyRate = 12.0,            # Монголбанкны бодлогын хүү, % (өөрчлөгдөхөд шинэчил)
  [string]$Reserves   = "",              # Гадаад валютын нөөц (ж: "4.9"); хоосон бол харуулахгүй
  [string]$ReservesUnit = "тэрбум $",    # нөөцийн нэгж
  [string]$CoalPrice  = ""               # Нүүрсний үнэ (ж: "112"); хоосон бол харуулахгүй
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---------- Монголбанк: албан ёсны өдрийн ханш ----------
function Get-MongolbankFX {
  param([int]$days)
  # currency-rate-movement/data → БҮХ өдрийн түүхийг буцаадаг (params үл хэрэгсдэг).
  $url   = "https://www.mongolbank.mn/mn/currency-rate-movement/data"
  $resp  = Invoke-RestMethod -Uri $url -Method Post -Body "{}" -ContentType "application/json" -TimeoutSec 90
  if (-not $resp.success) { throw "Монголбанк: success=false" }

  # RATE_DATE-ээр өсөхөөр эрэмбэлж, сүүлийн $days хоногийг авах
  $cut  = (Get-Date).AddDays(-$days)
  $rows = $resp.data |
    Where-Object { $_.USD -and ([datetime]$_.RATE_DATE) -ge $cut } |
    Sort-Object { [datetime]$_.RATE_DATE }
  if (-not $rows) { throw "Монголбанк: $days хоногт мөр алга" }
  $toNum = { param($s) [double](($s -replace ',', '')) }

  $series = @()
  $labels = @()
  foreach ($r in $rows) {
    $series += (& $toNum $r.USD)
    $labels += ([datetime]$r.RATE_DATE).ToString("yyyy.MM.dd")
  }
  $last = $rows[-1]
  [pscustomobject]@{
    latest = (& $toNum $last.USD)
    date   = ([datetime]$last.RATE_DATE).ToString("yyyy-MM-dd")
    series = $series
    labels = $labels
    # хүсвэл бусад валют ч энд (EUR/CNY/RUB...)
    eur    = (& $toNum $last.EUR)
    cny    = (& $toNum $last.CNY)
    rub    = (& $toNum $last.RUB)
  }
}

# ---------- МХБ TOP-20 (Next.js Server Action-аар) ----------
# www.mse.mn нь TOP-20-г "lO" нэртэй Next.js Server Action-аар татдаг.
# Үүнийг серверээс шууд дуудаж болно: POST mse.mn/ + Next-Action: <hash>,
# body=[{url:"top20Data",parameter:"?lang=mn",config:{hasToken:false}}].
# Хариу нь React-Flight; дотор нь [{date,value,high,low}, ...] бүх түүх ирнэ.
# ⚠ MSE сайтаа re-deploy хийхэд hash өөрчлөгдөж магадгүй — тиймээс эхлээд
#   chunk-аас hash-ийг АВТОМАТ олно, олдохгүй бол доорх fallback-ийг хэрэглэнэ.
$script:MseActionFallback = "6d867ebd99fb6edef2f9537b22668cd0c00a71c2"

function Get-MseActionHash {
  try {
    $home = (Invoke-WebRequest "https://www.mse.mn/" -TimeoutSec 30).Content
    $chunks = [regex]::Matches($home, '/_next/static/chunks/[A-Za-z0-9_./\-]+\.js') |
      ForEach-Object { $_.Value } | Select-Object -Unique
    foreach ($c in $chunks) {
      $js = (Invoke-WebRequest ("https://www.mse.mn" + $c) -TimeoutSec 30).Content
      if ($js -match 'lO:function') {
        $m = [regex]::Match($js, 'o=\(0,[a-zA-Z_$]+\.\$\)\("([0-9a-f]{40})"\)')
        if ($m.Success) { return $m.Groups[1].Value }
      }
    }
  } catch {}
  return $script:MseActionFallback
}

function Get-MseTop20 {
  param([int]$days = 45)
  $hash = Get-MseActionHash
  $body = '[{"url":"top20Data","parameter":"?lang=mn","config":{"hasToken":false}}]'
  $r = Invoke-WebRequest -Uri "https://www.mse.mn/" -Method Post `
        -Headers @{ 'Next-Action' = $hash } -Body $body `
        -ContentType 'text/plain;charset=UTF-8' -TimeoutSec 60
  # Flight хариунаас [{"date":...,"value":...}] массивтай мөрийг олох
  $line = ($r.Content -split "`n") | Where-Object { $_ -match '\[\{"date"' } | Select-Object -First 1
  if (-not $line) { throw "MSE: дата мөр олдсонгүй (hash хуучирсан байж магад)" }
  $arr = ($line -replace '^\d+:', '') | ConvertFrom-Json
  $arr = $arr | Where-Object { $_.value } | Sort-Object { [datetime]$_.date }
  $cut = (Get-Date).AddDays(-$days)
  $recent = $arr | Where-Object { ([datetime]$_.date) -ge $cut }
  if (-not $recent) { $recent = $arr | Select-Object -Last 11 }
  $last = $arr[-1]
  [pscustomobject]@{
    latest = [double]$last.value
    date   = ([datetime]$last.date).ToString("yyyy-MM-dd")
    series = @($recent | ForEach-Object { [double]$_.value })
    labels = @($recent | ForEach-Object { ([datetime]$_.date).ToString("yyyy.MM.dd") })
    source = "mse.mn server-action"
  }
}

# ---------- Түүхий эд (Yahoo Finance — 1 сарын өдөр тутмын series) ----------
# query2 host (query1 хаалттай). Алт=GC=F, Зэс=HG=F, Тос=CL=F. Throttle хийдэг тул retry.
function Get-YahooSeries {
  param([string]$sym)
  $url = "https://query2.finance.yahoo.com/v8/finance/chart/" + $sym + "?range=1mo&interval=1d"
  for ($i = 0; $i -lt 3; $i++) {
    try {
      $r = Invoke-WebRequest $url -TimeoutSec 25 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
      $res = ($r.Content | ConvertFrom-Json).chart.result[0]
      $cl = @($res.indicators.quote[0].close | Where-Object { $_ -ne $null } | ForEach-Object { [math]::Round([double]$_, 2) })
      if ($cl.Count -ge 2) {
        return [pscustomobject]@{ latest = $cl[-1]; series = $cl; date = (Get-Date).ToString("yyyy-MM-dd") }
      }
    } catch { Start-Sleep -Milliseconds 700 }
  }
  return $null
}
# Нүүрс — investing.com Newcastle coal (одоогийн үнэ, HTML-ээс)
function Get-CoalInvesting {
  try {
    $h = (Invoke-WebRequest "https://www.investing.com/commodities/newcastle-coal-futures-historical-data" `
          -TimeoutSec 30 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }).Content
    $m = [regex]::Match($h, 'last">([0-9,]+\.[0-9]+)')
    if ($m.Success) { return [double]($m.Groups[1].Value -replace ',', '') }
  } catch {}
  return $null
}

function Get-Commodities {
  $c = [ordered]@{}
  $map = [ordered]@{ gold = "GC=F"; copper = "HG=F"; oil = "CL=F" }
  foreach ($k in $map.Keys) {
    $v = Get-YahooSeries -sym $map[$k]
    if ($v) { $c[$k] = $v }
    Start-Sleep -Milliseconds 500
  }
  # Yahoo бүтэлгүйтвэл stockdata.json-оор нөхөх (зөвхөн одоогийн утга)
  if ($c.Count -lt 3) {
    try {
      $j = Invoke-RestMethod "https://ftp.bloombergtvmongolia.com/stockdata.json" -TimeoutSec 30
      $fb = @{ gold = 'XAU CURNCY'; copper = 'HG1 COMDTY'; oil = 'CL1 COMDTY' }
      foreach ($k in $fb.Keys) {
        if (-not $c[$k] -and $j.($fb[$k])) { $c[$k] = [pscustomobject]@{ latest = [double]$j.($fb[$k]).last_price; series = $null } }
      }
    } catch {}
  }
  return [pscustomobject]$c
}

# ---------- үндсэн ----------
$result = [ordered]@{
  updated     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  fx          = $null
  top20       = $null
  commodities = $null
  policy_rate = [pscustomobject]@{ latest = $PolicyRate; date = (Get-Date).ToString("yyyy-MM-dd"); note = "Монголбанк (гар тохиргоо)" }
  reserves    = $(if ($Reserves) { [pscustomobject]@{ latest = [double]$Reserves; unit = $ReservesUnit; note = "Монголбанк (гар тохиргоо)" } } else { $null })
  errors      = @()
}
try   { $result.fx = Get-MongolbankFX -days $Days; Write-Host ("FX OK: USD/MNT = {0} ({1}), {2} цэг" -f $result.fx.latest, $result.fx.date, $result.fx.series.Count) -ForegroundColor Green }
catch { $result.errors += "FX: $($_.Exception.Message)"; Write-Warning "FX алдаа: $($_.Exception.Message)" }

try   { $result.top20 = Get-MseTop20 -days $Days; Write-Host ("TOP20 OK: {0} ({1}), {2} цэг" -f $result.top20.latest, $result.top20.date, $result.top20.series.Count) -ForegroundColor Green }
catch { $result.errors += "TOP20: $($_.Exception.Message)"; Write-Warning "TOP20 алдаа: $($_.Exception.Message)" }

try {
  $result.commodities = Get-Commodities
  # нүүрс — investing.com-оос (Newcastle); олдохгүй бол -CoalPrice гар утга
  $coal = Get-CoalInvesting
  if (-not $coal -and $CoalPrice) { $coal = [double]$CoalPrice }
  if ($coal) { $result.commodities | Add-Member coal ([pscustomobject]@{ latest = $coal; changePct = $null; note = "investing.com Newcastle" }) }
  Write-Host ("Түүхий эд OK: алт={0} зэс={1} тос={2}" -f $result.commodities.gold.latest, $result.commodities.copper.latest, $result.commodities.oil.latest) -ForegroundColor Green
} catch { $result.errors += "Commodities: $($_.Exception.Message)"; Write-Warning "Commodities алдаа: $($_.Exception.Message)" }

# scrape_top20.mjs нь ижил файлд top20-г бичдэг тул мөргөлдөхгүйн тулд:
# энэ скрипт top20-г өөрөө аваагүй бол ӨМНӨХ top20-г хадгална.
$outFile = Join-Path $OutPath "live_extra.json"
if (($null -eq $result.top20) -and (Test-Path $outFile)) {
  try {
    $prev = Get-Content $outFile -Raw | ConvertFrom-Json
    if ($prev.top20) { $result.top20 = $prev.top20 }
  } catch {}
}

# live_extra.json бичих (UTF-8)
$json = ($result | ConvertTo-Json -Depth 6)
[System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Бичигдлээ: $outFile" -ForegroundColor Cyan
