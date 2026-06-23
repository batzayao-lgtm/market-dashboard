<#
  update_weekly.ps1 — NetCapital Insights (beehiiv)-ийн "7 хоногийн тойм"-ыг татаж weekly.json бичих
  --------------------------------------------------------------------------------------------------
  Эх: https://netcapital-insights.beehiiv.com/archive  → "weekly-market-brief-*" постууд.
  Пост бүрийн OpenGraph meta-аас гарчиг/тайлбар/зураг авна. CORS байхгүй тул server талд.
  Ажиллуулах: .\update_weekly.ps1 -OutPath .
#>
param(
  [string]$OutPath = ".",
  [string]$KeyFile = "economy-500301-47f5a778289e.json",
  [string]$SheetId = "1GbK2Td2HeddKgsidRmI61jdUenXO45Ck6IuFuP_BGfQ",
  [string]$WeeklyTab = "WEEKLY BRIEF",
  [int]$Max = 8,
  [int]$Year = 2026          # слагт зөвхөн сар-өдөр байдаг тул он
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "gsheet_lib.ps1")
$UA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) dashboard' }

# Эх сурвалжийг sheet-ийн WEEKLY BRIEF таб-аас (beehiiv archive линк)
$wsrc = Get-SheetSources $KeyFile $SheetId $WeeklyTab
$archiveUrl = ($wsrc | Where-Object { $_ -match 'beehiiv' } | Select-Object -First 1)
if (-not $archiveUrl) { $archiveUrl = "https://netcapital-insights.beehiiv.com/archive" }
$SITE = ($archiveUrl -replace '(/archive.*$)','')
Write-Host "WEEKLY эх: $archiveUrl" -ForegroundColor Cyan

function Meta($html, $prop) {
  $p = [regex]::Escape($prop)
  $m = [regex]::Match($html, '<meta[^>]+(?:property|name)="' + $p + '"[^>]+content="([^"]*)"')
  if (-not $m.Success) { $m = [regex]::Match($html, '<meta[^>]+content="([^"]*)"[^>]+(?:property|name)="' + $p + '"') }
  return $m.Groups[1].Value
}

# 1) archive-аас weekly-market-brief слагуудыг (дарааллаар, давхардалгүй) авах
$arch = (Invoke-WebRequest "$SITE/archive" -TimeoutSec 40 -Headers $UA).Content
$slugs = [regex]::Matches($arch, '/p/(weekly-market-brief-[a-z0-9\-]+)') |
  ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First $Max

$items = @()
$errors = @()
foreach ($slug in $slugs) {
  try {
    $url = "$SITE/p/$slug"
    $h = (Invoke-WebRequest $url -TimeoutSec 40 -Headers $UA).Content
    $title = Meta $h 'og:title'; if (-not $title) { $title = $slug }
    $desc  = Meta $h 'og:description'
    $img   = Meta $h 'og:image'
    # огноо: слагийн MM-DD-аас
    $dm = [regex]::Match($slug, '(\d{2})-(\d{2})')
    $date = if ($dm.Success) { "$Year-$($dm.Groups[1].Value)-$($dm.Groups[2].Value)" } else { "" }
    $items += [pscustomobject]@{ title = $title; description = $desc; url = $url; image = $img; date = $date }
  } catch { $errors += "$slug : $($_.Exception.Message)" }
}

# огноогоор шинээс нь эрэмбэлэх
$items = $items | Sort-Object { try { [datetime]$_.date } catch { [datetime]"1900-01-01" } } -Descending

$result = [ordered]@{
  updated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  source  = "NetCapital Insights (beehiiv)"
  count   = $items.Count
  items   = $items
  errors  = $errors
}
$out = Join-Path $OutPath "weekly.json"
[System.IO.File]::WriteAllText($out, ($result | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
Write-Host ("7 хоногийн тойм {0} ширхэг → {1}" -f $items.Count, $out) -ForegroundColor Green
$items | Select-Object -First 6 | ForEach-Object { Write-Host ("  [{0}] {1}" -f $_.date, $_.title) -ForegroundColor DarkGray }
