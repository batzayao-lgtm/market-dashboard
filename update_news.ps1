<#
  update_news.ps1 — Google Sheet-ийн эх сурвалжийн жагсаалтаас мэдээ татаж news.json бичих
  ----------------------------------------------------------------------------------------
  Эх сурвалжуудыг "Market news" sheet-ийн NEWS таб-аас уншина (service account-аар).
  Тухайн линкийн домэйнээр нь зөв парсер сонгоно: bloombergtv / cnbc.mn / mining.mn.
  Шинэ сайт нэмэх: sheet-д линк нэмээд (parser байвал) ажиллана.

  Ажиллуулах: .\update_news.ps1 -OutPath .
#>
param(
  [string]$OutPath = ".",
  [string]$KeyFile = "economy-500301-47f5a778289e.json",
  [string]$SheetId = "1GbK2Td2HeddKgsidRmI61jdUenXO45Ck6IuFuP_BGfQ",
  [string]$NewsTab = "NEWS",
  [string]$ManualFile = "manual_news.json",
  [string]$Since = "2026-05-01",
  [int]$PerSource = 12,
  [int]$Max = 80
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "gsheet_lib.ps1")
$UA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) dashboard' }

function Get-Meta($html, $prop) {
  $p = [regex]::Escape($prop)
  $m = [regex]::Match($html, '<meta[^>]+(?:property|name)="' + $p + '"[^>]+content="([^"]*)"')
  if (-not $m.Success) { $m = [regex]::Match($html, '<meta[^>]+content="([^"]*)"[^>]+(?:property|name)="' + $p + '"') }
  return $m.Groups[1].Value
}

# ---------- bloombergtv.mn (Next.js __NEXT_DATA__) ----------
function Get-BloombergNews($url) {
  $html = (Invoke-WebRequest $url -TimeoutSec 40 -Headers $UA).Content
  $m = [regex]::Match($html, '<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $m.Success) { throw "bloombergtv: __NEXT_DATA__ алга" }
  $d = ($m.Groups[1].Value | ConvertFrom-Json).props.pageProps.data
  $out = @()
  foreach ($n in (@($d.featurednews) + @($d.news))) {
    if (-not $n.slug) { continue }
    $img = if ($n.news_images -and $n.news_images[0].image) { "https://www.bloombergtv.mn$($n.news_images[0].image)" } else { $null }
    $out += [pscustomobject]@{ title=$n.title; description=$n.description; url="https://www.bloombergtv.mn/news/$($n.slug)"; category=$n.category.name; source="Bloomberg TV Mongolia"; date=$n.createdAt; image=$img }
  }
  return $out
}

# ---------- cnbc.mn (/news/<id> + article OG) ----------
function Get-CnbcNews($url, $take) {
  $html = (Invoke-WebRequest $url -TimeoutSec 40 -Headers $UA).Content
  $ids = [regex]::Matches($html, '/news/([a-z0-9]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First $take
  $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $out = @()
  foreach ($id in $ids) {
    try {
      $a = (Invoke-WebRequest "https://cnbc.mn/news/$id" -TimeoutSec 30 -Headers $UA).Content
      $t = Get-Meta $a 'og:title'; if (-not $t) { continue }
      $img = Get-Meta $a 'og:image'
      $out += [pscustomobject]@{ title=$t.Trim(); description=""; url="https://cnbc.mn/news/$id"; category="CNBC"; source="CNBC Mongolia"; date=$now; image=$img }
    } catch {}
  }
  return $out
}

# ---------- mining.mn (HTML картууд) ----------
function Get-MiningNews($url, $take) {
  $html = (Invoke-WebRequest $url -TimeoutSec 40 -Headers $UA).Content
  $rx = [regex]'(?s)<a href="(https?://mining\.mn/content/\d+)">\s*(.*?)\s*</a>.*?(\d{4}\.\d{2}\.\d{2})'
  $out = @()
  foreach ($m in ($rx.Matches($html) | Select-Object -First $take)) {
    $title = ($m.Groups[2].Value -replace '<[^>]+>','').Trim()
    if (-not $title) { continue }
    $date = ($m.Groups[3].Value -replace '\.','-')
    $out += [pscustomobject]@{ title=$title; description=""; url=$m.Groups[1].Value; category="Уул уурхай"; source="Mining.mn"; date="$date 00:00:00"; image=$null }
  }
  return $out
}

# ---------- гараас оруулсан ----------
function Get-ManualNews($file) {
  if (-not (Test-Path $file)) { return @() }
  $raw = [System.IO.File]::ReadAllText((Resolve-Path $file), [System.Text.Encoding]::UTF8)
  if (-not $raw.Trim()) { return @() }
  return @($raw | ConvertFrom-Json) | Where-Object { $_.title -and $_.url -and $_.url -notmatch 'example\.com' } | ForEach-Object {
    [pscustomobject]@{ title=$_.title; description=$_.description; url=$_.url
      category= if ($_.category) { $_.category } else { "Онцлох" }
      source= if ($_.source) { $_.source } else { "Гар оруулга" }
      date= if ($_.date) { $_.date } else { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
      image=$_.image }
  }
}

# ---------- эх сурвалжийг sheet-аас уншиж дамжуулах ----------
$sources = Get-SheetSources $KeyFile $SheetId $NewsTab
Write-Host ("Sheet-ээс {0} эх сурвалж: {1}" -f $sources.Count, ($sources -join ', ')) -ForegroundColor Cyan
$all = @(); $errors = @()
foreach ($src in $sources) {
  try {
    if     ($src -match 'bloombergtv\.mn') { $all += Get-BloombergNews $src }
    elseif ($src -match 'cnbc\.mn')        { $all += Get-CnbcNews $src $PerSource }
    elseif ($src -match 'mining\.mn')      { $all += Get-MiningNews $src $PerSource }
    else { $errors += "Парсер алга: $src"; Write-Warning "Парсер алга: $src" }
  } catch { $errors += "$src : $($_.Exception.Message)"; Write-Warning "$src : $($_.Exception.Message)" }
}
try { $all += Get-ManualNews (Join-Path $OutPath $ManualFile) } catch { $errors += "Manual: $($_.Exception.Message)" }

# HTML entity задлах (&quot; &amp; гэх мэт)
foreach ($it in $all) {
  if ($it.title) { $it.title = [System.Net.WebUtility]::HtmlDecode($it.title) }
  if ($it.description) { $it.description = [System.Net.WebUtility]::HtmlDecode($it.description) }
}

# шүүлт: бодит линк + огноо [Since→өнөөдөр], давхардалгүй, шинээр эрэмбэлсэн
$since = [datetime]$Since; $until = (Get-Date).Date.AddDays(1)
$news = $all | Where-Object {
  if (-not $_.url -or $_.url -notmatch '^https?://' -or $_.url -match 'example\.|/news/null') { return $false }
  $d=[datetime]::MinValue; if (-not [datetime]::TryParse([string]$_.date, [ref]$d)) { return $false }
  ($d -ge $since) -and ($d -le $until)
} | Sort-Object url -Unique | Sort-Object { [datetime]$_.date } -Descending | Select-Object -First $Max

$result = [ordered]@{
  updated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  source  = "Google Sheet (NEWS) → " + (($sources -replace 'https?://([^/]+).*','$1') -join ', ')
  count   = $news.Count
  news    = $news
  errors  = $errors
}
$out = Join-Path $OutPath "news.json"
[System.IO.File]::WriteAllText($out, ($result | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
Write-Host ("Мэдээ {0} ширхэг → {1}" -f $news.Count, $out) -ForegroundColor Green
$news | Group-Object source | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Name, $_.Count) -ForegroundColor DarkGray }
