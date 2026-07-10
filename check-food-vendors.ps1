<#
.SYNOPSIS
  Fetches the current Gen Con Block Party page and saves it locally so it can be
  compared against food.html's current vendor list. Unlike the exhibitor
  directory, this page isn't a structured API - a person (or Claude) still needs
  to read the diff and decide what changed in the writeup.

.EXAMPLE
  .\check-food-vendors.ps1
#>
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$outPath = Join-Path $root ("blockparty_raw_" + (Get-Date -Format "yyyy-MM-dd") + ".html")

Write-Output "Fetching https://www.gencon.com/gen-con-indy/block-party ..."
Invoke-WebRequest -Uri "https://www.gencon.com/gen-con-indy/block-party" -OutFile $outPath -TimeoutSec 30
Write-Output ("Saved raw page to: " + $outPath)

Write-Output ""
Write-Output "Current vendors listed in food.html:"
$foodHtml = Get-Content (Join-Path $root "food.html") -Raw -Encoding UTF8
$matches = [regex]::Matches($foodHtml, '<div class="vendor-name">([^<]+)')
$matches | ForEach-Object { Write-Output ("  - " + $_.Groups[1].Value.Trim()) }

Write-Output ""
Write-Output "Next step: ask Claude to 'check the food guide against blockparty_raw_<date>.html and update food.html' - it'll read both and rewrite the vendor list/menus for anything that changed."
