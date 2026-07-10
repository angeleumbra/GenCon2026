<#
.SYNOPSIS
  Full refresh pipeline for the Gen Con 2026 Exhibitor Directory.
  Re-pages the live exhibitor API, detects new/removed/changed exhibitors,
  fetches descriptions for anything new, rebuilds the dataset, re-embeds it
  into exhibitors.html, and commits + pushes to GitHub.

.PARAMETER Push
  Whether to git commit + push automatically when done. Default true.

.PARAMETER SkipNewDescriptions
  If set, don't fetch descriptions for newly-discovered exhibitors (faster,
  but new entries will show "No description provided" until you run
  crawl-exhibitors.ps1 afterward).

.EXAMPLE
  .\refresh-exhibitors.ps1
  .\refresh-exhibitors.ps1 -Push:$false
#>
param(
    [bool]$Push = $true,
    [switch]$SkipNewDescriptions
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$enrichedPath = Join-Path $root "exhibitors_enriched.csv"
$directoryPath = Join-Path $root "exhibitors_for_directory.csv"
$htmlPath = Join-Path $root "exhibitors.html"

Write-Output "=== Step 1: Fetching live exhibitor list from Gen Con's API ==="
$live = @{}
$page = 1
$totalPages = 40
while ($page -le $totalPages) {
    $url = "https://www.gencon.com/api/v1/exhibitor_profiles?convention_id=27&page=$page"
    $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20
    if ($resp.meta -and $resp.meta.totalPages) { $totalPages = $resp.meta.totalPages }
    $entries = $resp.exhibitors
    if (-not $entries -or $entries.Count -eq 0) { break }
    foreach ($e in $entries) {
        if (-not $e.name) { continue }
        $name = $e.name.Trim()
        $zoneParsed = ""
        $boothIds = @()
        if ($e.locations -and $e.locations.Count -gt 0) {
            foreach ($loc in $e.locations) {
                # Label looks like "Exhibit Hall : Booth 2909" or "Art Show : Table 25"
                if ($loc.label -match '^([^:]+?)\s*:\s*(?:Booth|Table)\s*(.+)$') {
                    if (-not $zoneParsed) { $zoneParsed = $matches[1].Trim() }
                    $boothIds += $matches[2].Trim()
                } elseif ($loc.label) {
                    $boothIds += $loc.label.Trim()
                }
            }
        }
        $live[$name] = [PSCustomObject]@{
            Id = $e.id
            Name = $name
            Type = $e.exhibitorType
            Zone = $zoneParsed
            Booths = ($boothIds -join ", ")
            Tags = ($e.tags -join "; ")
            Sponsor = [string]$e.isSponsor
        }
    }
    $page++
}
Write-Output ("Live exhibitor count: " + $live.Count)

Write-Output "=== Step 2: Comparing against existing dataset ==="
$existing = @{}
if (Test-Path $enrichedPath) {
    Import-Csv $enrichedPath | ForEach-Object { $existing[$_.Name.Trim()] = $_ }
}
Write-Output ("Existing dataset count: " + $existing.Count)

$newNames = $live.Keys | Where-Object { -not $existing.ContainsKey($_) }
$removedNames = $existing.Keys | Where-Object { -not $live.ContainsKey($_) }

Write-Output ("New exhibitors found: " + $newNames.Count)
if ($newNames.Count -gt 0) { $newNames | ForEach-Object { Write-Output ("  + " + $_) } }
Write-Output ("Exhibitors no longer listed: " + $removedNames.Count)
if ($removedNames.Count -gt 0) { $removedNames | ForEach-Object { Write-Output ("  - " + $_) } }

$boothChanges = @()
foreach ($name in $existing.Keys) {
    if ($live.ContainsKey($name)) {
        $oldBooth = ($existing[$name].Booths -replace '\s+', ' ').Trim()
        $newBooth = ($live[$name].Booths -replace '\s+', ' ').Trim()
        if ($oldBooth -ne $newBooth -and $newBooth) {
            $boothChanges += "$name : '$oldBooth' -> '$newBooth'"
        }
    }
}
Write-Output ("Booth/location changes: " + $boothChanges.Count)
$boothChanges | ForEach-Object { Write-Output ("  * " + $_) }

Write-Output "=== Step 3: Rebuilding dataset ==="
$updated = @()
foreach ($name in $existing.Keys) {
    if ($removedNames -contains $name) { continue } # drop removed exhibitors
    $row = $existing[$name]
    if ($live.ContainsKey($name)) {
        $row.Type = $live[$name].Type
        $row.Booths = $live[$name].Booths
        $row.Tags = $live[$name].Tags
        $row.Sponsor = $live[$name].Sponsor
    }
    $updated += $row
}
foreach ($name in $newNames) {
    $l = $live[$name]
    $updated += [PSCustomObject]@{
        Name = $l.Name; Type = $l.Type; Zone = $l.Zone; Booths = $l.Booths
        Tags = $l.Tags; Sponsor = $l.Sponsor; Title = ""
        Description = ""; Website = ""
    }
}

if (-not $SkipNewDescriptions -and $newNames.Count -gt 0) {
    Write-Output ("=== Step 4: Fetching descriptions for " + $newNames.Count + " new exhibitors ===")
    foreach ($row in $updated) {
        if (($newNames -contains $row.Name) -and $live.ContainsKey($row.Name)) {
            $id = $live[$row.Name].Id
            try {
                $detail = Invoke-RestMethod -Uri "https://www.gencon.com/api/v1/exhibitor_profiles/$id`?convention_id=27" -Method Get -TimeoutSec 20
                $row.Description = if ($detail.description) { $detail.description } else { "No description provided" }
                $row.Website = if ($detail.website -and $detail.website.navigateTo) { $detail.website.navigateTo } else { "" }
            } catch {
                $row.Description = "No description provided"
            }
            Start-Sleep -Milliseconds 200
        }
    }
} elseif ($newNames.Count -gt 0) {
    Write-Output "Skipping description fetch for new exhibitors (-SkipNewDescriptions set)."
}

$updated | Export-Csv -Path $enrichedPath -NoTypeInformation -Encoding UTF8
$forDirectory = $updated | Where-Object { $_.Type -ne "Food & Drink" }
$forDirectory | Export-Csv -Path $directoryPath -NoTypeInformation -Encoding UTF8
Write-Output ("Saved. Total: " + $updated.Count + " | In directory (non-food): " + $forDirectory.Count)

Write-Output "=== Step 5: Re-embedding into exhibitors.html ==="
$csvBytes = [System.IO.File]::ReadAllBytes($directoryPath)
$csvB64 = [Convert]::ToBase64String($csvBytes)
$html = Get-Content -Path $htmlPath -Raw -Encoding UTF8
$idx = $html.IndexOf('var CSV_B64 = "')
$endIdx = $html.IndexOf('";', $idx) + 2
$html = $html.Substring(0, $idx) + 'var CSV_B64 = "' + $csvB64 + '";' + $html.Substring($endIdx)

# Update the "X shown" / "All X" counts in the page text to match the new total
$newCount = $forDirectory.Count
$html = $html -replace 'All \d+ non-food exhibiting', "All $newCount non-food exhibiting"
$html = $html -replace 'id="count-tag">\d+ shown', "id=`"count-tag`">$newCount shown"

Set-Content -Path $htmlPath -Value $html -Encoding UTF8 -NoNewline
Write-Output "exhibitors.html updated."

if ($Push) {
    Write-Output "=== Step 6: Committing and pushing ==="
    Set-Location $root
    git add exhibitors.html
    $msg = "Refresh exhibitor data: +$($newNames.Count) new, -$($removedNames.Count) removed, $($boothChanges.Count) booth changes"
    git commit -m $msg
    git push
    Write-Output "Pushed to GitHub."
} else {
    Write-Output "Skipping git push (-Push:`$false). Changes are saved locally only."
}

Write-Output ""
Write-Output "=== Summary ==="
Write-Output ("New exhibitors: " + $newNames.Count)
Write-Output ("Removed exhibitors: " + $removedNames.Count)
Write-Output ("Booth changes: " + $boothChanges.Count)
Write-Output ("Total in directory now: " + $forDirectory.Count)
