<#
  gsheet_lib.ps1 — Google service account JWT (RS256) → access token → Sheets API
  .NET Framework 4.8-д ImportPkcs8PrivateKey байхгүй тул PKCS#8 DER-ийг гараар задална.
  Dot-source: . .\gsheet_lib.ps1
#>

function ConvertTo-Base64Url([byte[]]$bytes){
  [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

# --- PKCS#8 PEM → RSACryptoServiceProvider ---
function Import-RsaFromPkcs8Pem([string]$pem){
  $b64 = ($pem -replace '-----BEGIN PRIVATE KEY-----','' -replace '-----END PRIVATE KEY-----','' -replace '\s','')
  $der = [Convert]::FromBase64String($b64)
  $pos = 0
  function _len([byte[]]$d,[ref]$p){
    $b=$d[$p.Value]; $p.Value++
    if($b -lt 0x80){ return [int]$b }
    $n=$b -band 0x7f; $len=0
    for($i=0;$i -lt $n;$i++){ $len=($len*256)+$d[$p.Value]; $p.Value++ }
    return [int]$len
  }
  function _int([byte[]]$d,[ref]$p){
    if($d[$p.Value] -ne 0x02){ throw "ASN.1: INTEGER хүлээж байсан ($($d[$p.Value]))" }
    $p.Value++
    $l=_len $d $p
    $bytes=$d[$p.Value..($p.Value+$l-1)]; $p.Value+=$l
    while($bytes.Length -gt 1 -and $bytes[0] -eq 0){ $bytes=$bytes[1..($bytes.Length-1)] }
    return ,([byte[]]$bytes)
  }
  function _pad([byte[]]$b,[int]$L){ if($b.Length -eq $L){return $b}; $o=New-Object byte[] $L; [Array]::Copy($b,0,$o,$L-$b.Length,$b.Length); return $o }

  $pp=[ref]$pos
  if($der[$pp.Value] -ne 0x30){ throw "PKCS8: SEQ алга" }; $pp.Value++; [void](_len $der $pp)   # outer SEQ
  [void](_int $der $pp)                                                                          # version
  if($der[$pp.Value] -ne 0x30){ throw "PKCS8: AlgId алга" }; $pp.Value++; $al=_len $der $pp; $pp.Value+=$al  # skip AlgorithmIdentifier
  if($der[$pp.Value] -ne 0x04){ throw "PKCS8: OCTET алга" }; $pp.Value++; [void](_len $der $pp)  # OCTET STRING → inner PKCS#1
  if($der[$pp.Value] -ne 0x30){ throw "PKCS1: SEQ алга" }; $pp.Value++; [void](_len $der $pp)    # inner SEQ
  [void](_int $der $pp)                                                                          # version
  $n=_int $der $pp; $e=_int $der $pp; $d=_int $der $pp
  $p1=_int $der $pp; $q=_int $der $pp; $dp=_int $der $pp; $dq=_int $der $pp; $iq=_int $der $pp

  $kl=$n.Length; $hl=[int][math]::Ceiling($kl/2)
  $rp=New-Object System.Security.Cryptography.RSAParameters
  $rp.Modulus=$n; $rp.Exponent=$e
  $rp.D=(_pad $d $kl); $rp.P=(_pad $p1 $hl); $rp.Q=(_pad $q $hl)
  $rp.DP=(_pad $dp $hl); $rp.DQ=(_pad $dq $hl); $rp.InverseQ=(_pad $iq $hl)
  $rsa=New-Object System.Security.Cryptography.RSACryptoServiceProvider
  $rsa.ImportParameters($rp)
  return $rsa
}

# --- service account → access token ---
function Get-GoogleAccessToken([string]$keyFile,[string]$scope="https://www.googleapis.com/auth/spreadsheets"){
  $k=[System.IO.File]::ReadAllText($keyFile,[System.Text.Encoding]::UTF8)|ConvertFrom-Json
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $header=@{alg="RS256";typ="JWT"}|ConvertTo-Json -Compress
  $claim=@{ iss=$k.client_email; scope=$scope; aud=$k.token_uri; iat=$now; exp=$now+3600 }|ConvertTo-Json -Compress
  $hi=ConvertTo-Base64Url([Text.Encoding]::UTF8.GetBytes($header))
  $ci=ConvertTo-Base64Url([Text.Encoding]::UTF8.GetBytes($claim))
  $signingInput="$hi.$ci"
  $rsa=Import-RsaFromPkcs8Pem $k.private_key
  $sig=$rsa.SignData([Text.Encoding]::UTF8.GetBytes($signingInput),[System.Security.Cryptography.HashAlgorithmName]::SHA256,[System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
  $jwt="$signingInput."+(ConvertTo-Base64Url $sig)
  $body="grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=$jwt"
  $resp=Invoke-RestMethod -Uri $k.token_uri -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -TimeoutSec 40
  return $resp.access_token
}

# --- Sheet-ийн нүднүүдийг унших ---
function Get-SheetValues([string]$keyFile,[string]$spreadsheetId,[string]$range){
  $tok=Get-GoogleAccessToken -keyFile $keyFile
  $enc=[System.Uri]::EscapeDataString($range)
  $r=Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$spreadsheetId/values/$enc" -Headers @{ Authorization="Bearer $tok" } -TimeoutSec 40
  return $r.values
}

# --- Tab-аас бүх эх сурвалжийн URL (https-ээр эхэлсэн нүд) ---
function Get-SheetSources([string]$keyFile,[string]$spreadsheetId,[string]$tab){
  $vals=Get-SheetValues $keyFile $spreadsheetId "$tab!A1:D200"
  $urls=New-Object System.Collections.Generic.List[string]
  foreach($row in $vals){ foreach($cell in $row){ if("$cell" -match '^\s*https?://'){ $urls.Add(("$cell").Trim()) } } }
  return ($urls | Select-Object -Unique)
}
