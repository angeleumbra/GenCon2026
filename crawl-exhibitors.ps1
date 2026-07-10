<#
.SYNOPSIS
  Resumable crawler that pulls real descriptions/websites for Gen Con 2026 exhibitors
  from Gen Con's own exhibitor-profile API, in batches, and merges them into
  exhibitors_enriched.csv.

.PARAMETER BatchSize
  How many new exhibitors to fetch full details for in this run. Default 50.

.EXAMPLE
  .\crawl-exhibitors.ps1
  .\crawl-exhibitors.ps1 -BatchSize 100
#>
param(
    [int]$BatchSize = 50
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$baseCsvPath = Join-Path $root "exhibitors_base.csv"
$enrichedCsvPath = Join-Path $root "exhibitors_enriched.csv"
$idMapPath = Join-Path $root "id_map.json"

if (-not (Test-Path $baseCsvPath)) {
    throw "Missing $baseCsvPath - base exhibitor list not found."
}

# --- Load or build the name -> {id, booth} map (cached so we don't re-page 30 list pages every run) ---
$idMap = @{}
if (Test-Path $idMapPath) {
    $raw = Get-Content $idMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $raw.PSObject.Properties) {
        $idMap[$prop.Name] = @{ id = $prop.Value.id; booth = $prop.Value.booth }
    }
    Write-Output ("Loaded cached id map: " + $idMap.Count + " names.")
}

$baseRows = Import-Csv $baseCsvPath
$namesNeeded = $baseRows | ForEach-Object { $_.Name.Trim() } | Where-Object { -not $idMap.ContainsKey($_) }

if ($namesNeeded.Count -gt 0) {
    Write-Output ("Building id map for " + $namesNeeded.Count + " names not yet cached (paging the bulk list API)...")
    $needSet = @{}
    foreach ($n in $namesNeeded) { $needSet[$n] = $true }

    $page = 1
    $totalPages = 40 # updated once meta is known
    while ($page -le $totalPages) {
        $url = "https://www.gencon.com/api/v1/exhibitor_profiles?convention_id=27&page=$page"
        try {
            $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20
        } catch {
            Write-Output ("  Page $page fetch failed: " + $_.Exception.Message + " - stopping pagination.")
            break
        }
        if ($resp.meta -and $resp.meta.totalPages) { $totalPages = $resp.meta.totalPages }
        $entries = $resp.exhibitors
        if (-not $entries -or $entries.Count -eq 0) { break }

        foreach ($entry in $entries) {
            $entryName = if ($entry.name) { $entry.name.Trim() } else { $null }
            if ($entryName -and $needSet.ContainsKey($entryName)) {
                $boothLabel = if ($entry.locations -and $entry.locations.Count -gt 0) { $entry.locations[0].label } else { "" }
                $idMap[$entryName] = @{ id = $entry.id; booth = $boothLabel }
            }
        }
        $page++
    }

    # Persist the updated map
    $idMap | ConvertTo-Json -Depth 5 | Set-Content -Path $idMapPath -Encoding UTF8
    Write-Output ("Id map now covers " + $idMap.Count + " of " + $baseRows.Count + " names.")
}

# --- Load current enriched data (or initialize from base if missing) ---
if (Test-Path $enrichedCsvPath) {
    $enriched = Import-Csv $enrichedCsvPath
} else {
    $enriched = $baseRows | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name; Type = $_.Type; Zone = $_.Zone; Booths = $_.Booths
            Tags = $_.Tags; Sponsor = $_.Sponsor; Title = $_.Title
            Description = ""; Website = ""
        }
    }
}
$enrichedByName = @{}
foreach ($row in $enriched) { $enrichedByName[$row.Name.Trim()] = $row }

# --- Figure out which names still need a real description ---
$stillNeeded = @()
foreach ($row in $enriched) {
    $d = $row.Description
    if (-not $d -or $d -eq "" -or $d -eq "No description provided") {
        $stillNeeded += $row.Name.Trim()
    }
}

Write-Output ("Total exhibitors: " + $enriched.Count)
Write-Output ("Already have real descriptions: " + ($enriched.Count - $stillNeeded.Count))
Write-Output ("Still needed: " + $stillNeeded.Count)

if ($stillNeeded.Count -eq 0) {
    Write-Output "All exhibitors already have descriptions. Nothing to do."
    exit 0
}

$thisBatch = $stillNeeded | Select-Object -First $BatchSize
Write-Output ("Fetching this batch: " + $thisBatch.Count + " exhibitors...")

$fetched = 0
$failed = @()
foreach ($name in $thisBatch) {
    if (-not $idMap.ContainsKey($name)) {
        $failed += "$name (no id found in map)"
        continue
    }
    $id = $idMap[$name].id
    $url = "https://www.gencon.com/api/v1/exhibitor_profiles/$id`?convention_id=27"
    try {
        $detail = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20
        $desc = if ($detail.description) { $detail.description } else { "No description provided" }
        $site = if ($detail.website -and $detail.website.navigateTo) { $detail.website.navigateTo } else { "" }

        $row = $enrichedByName[$name]
        $row.Description = $desc
        $row.Website = $site
        $fetched++
    } catch {
        $failed += "$name (fetch error: $($_.Exception.Message))"
    }
    Start-Sleep -Milliseconds 200
}

$enriched | Export-Csv -Path $enrichedCsvPath -NoTypeInformation -Encoding UTF8

Write-Output ""
Write-Output ("Batch complete. Fetched: $fetched / " + $thisBatch.Count)
if ($failed.Count -gt 0) {
    Write-Output ("Failed (" + $failed.Count + "):")
    $failed | ForEach-Object { Write-Output ("  - " + $_) }
}
$remaining = $stillNeeded.Count - $fetched
Write-Output ("Remaining after this run: " + $remaining + " of " + $enriched.Count)
Write-Output ("Run again with the same command to fetch the next batch.")
