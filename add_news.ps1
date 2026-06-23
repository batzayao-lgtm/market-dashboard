<#
  add_news.ps1 — гараас мэдээ нэмэх хялбар туслах (manual_news.json-д бичнэ)
  ---------------------------------------------------------------------------
  Жишээ:
    .\add_news.ps1 -Title "ХХБ хувьцаа эзэмшигчдэд ногдол ашиг зарлав" -Url "https://example.mn/123" -Category "Ногдол ашиг"
    .\add_news.ps1 -Title "Олон улсын чухал мэдээ" -Url "https://reuters.com/x" -Category "Олон улс" -Image "https://.../pic.jpg"
  Дараа: .\update_news.ps1 -OutPath .   (news.json-д нийлүүлнэ)
#>
param(
  [Parameter(Mandatory)][string]$Title,
  [Parameter(Mandatory)][string]$Url,
  [string]$Description = "",
  [string]$Source = "Гар оруулга",
  [string]$Category = "Онцлох",
  [string]$Image = $null,
  [string]$Date = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),
  [string]$File = "manual_news.json"
)
$ErrorActionPreference = "Stop"

$list = @()
if (Test-Path $File) {
  $raw = [System.IO.File]::ReadAllText((Resolve-Path $File), [System.Text.Encoding]::UTF8)
  if ($raw.Trim()) {
    # жишээ мөрийг (example.com) автоматаар алгасах
    $list = @($raw | ConvertFrom-Json) | Where-Object { $_.url -and $_.url -notmatch 'example\.com' }
  }
}
$list = @($list)   # массив байхыг баталгаажуул
$list += [pscustomobject]@{ title=$Title; description=$Description; url=$Url; category=$Category; source=$Source; date=$Date; image=$Image }

# нэг элементтэй ч ЗААВАЛ JSON массив [...] болгож бичих
$json = $list | ConvertTo-Json -Depth 5
if ($list.Count -eq 1) { $json = "[$json]" }
[System.IO.File]::WriteAllText($File, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host ("Нэмэгдлээ ({0} мэдээ): [{1}] {2}" -f $list.Count, $Category, $Title) -ForegroundColor Green
Write-Host "Одоо ажиллуул: .\update_news.ps1 -OutPath ." -ForegroundColor DarkGray
