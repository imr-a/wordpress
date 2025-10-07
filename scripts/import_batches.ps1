param(
    [int]$BatchSize = 10,
    [string]$BranchName = 'import-local-folders'
)

# Determine source (parent folder) and destination (current repo folder)
$dst = (Get-Location).Path
$src = Split-Path -Parent $dst
$dstName = Split-Path $dst -Leaf

Write-Host "Destination repo: $dst"
Write-Host "Importing from parent folder: $src"
Write-Host "Excluding destination folder name: $dstName and .git"

# Prepare branch
git fetch origin
if ($LASTEXITCODE -ne 0) { Write-Host 'git fetch failed'; exit 1 }

# Ensure we start from up-to-date main
git checkout main
if ($LASTEXITCODE -ne 0) { Write-Host 'git checkout main failed'; exit 1 }

git pull --rebase origin main
if ($LASTEXITCODE -ne 0) { Write-Host 'git pull failed'; exit 1 }

# Create or reset the import branch
git checkout -B $BranchName
if ($LASTEXITCODE -ne 0) { Write-Host "git checkout -B $BranchName failed"; exit 1 }

# Gather items to import (top-level only)
$items = Get-ChildItem -Path $src -Force | Where-Object { $_.Name -ne $dstName -and $_.Name -ne '.git' } | Sort-Object Name

if ($items.Count -eq 0) {
    Write-Host 'No items found to import.'
    exit 0
}

# Filter out items that already exist in destination
$toImport = @()
foreach ($it in $items) {
    $targetPath = Join-Path $dst $it.Name
    if (Test-Path $targetPath) {
        Write-Host "Skipping existing: $($it.Name)"
    } else {
        $toImport += $it
    }
}

if ($toImport.Count -eq 0) {
    Write-Host 'All items already exist in destination. Nothing to import.'
    exit 0
}

# Build batches
$batches = @()
for ($i = 0; $i -lt $toImport.Count; $i += $BatchSize) {
    $end = [math]::Min($i + $BatchSize - 1, $toImport.Count - 1)
    $batches += ,@($toImport[$i..$end])
}

$firstPush = $true
$batchIndex = 1

foreach ($batch in $batches) {
    $names = $batch | ForEach-Object { $_.Name }
    Write-Host ("\nProcessing batch {0}: {1}" -f $batchIndex, ($names -join ', '))

    foreach ($it in $batch) {
        $dstPath = Join-Path $dst $it.Name
        try {
            if ($it.PSIsContainer) {
                Copy-Item -Path $it.FullName -Destination $dstPath -Recurse -Force -ErrorAction Stop
            } else {
                Copy-Item -Path $it.FullName -Destination $dstPath -Force -ErrorAction Stop
            }
            Write-Host "Copied: $($it.Name)"
        } catch {
            Write-Host "Failed to copy $($it.Name): $_"
        }
    }

    # Check git status and commit
    $st = git status --porcelain
    if ($st) {
        git add -A
        $msgNames = ($names -join ', ')
        $msg = "chore(import): add batch $batchIndex - $msgNames"
        git commit -m $msg
        if ($LASTEXITCODE -ne 0) {
            Write-Host "git commit failed for batch $batchIndex"; exit 1
        }

        if ($firstPush) {
            git push -u origin $BranchName
            $firstPush = $false
        } else {
            git push
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "git push failed for batch $batchIndex"; exit 1
        }
        Write-Host "Pushed batch $batchIndex"
    } else {
        Write-Host "No changes to commit for batch $batchIndex"
    }

    $batchIndex++
}

Write-Host '\nImport complete. Recent commits:'
git log --oneline -n 10

Write-Host "\nTo create a PR on GitHub, visit: https://github.com/$(git remote get-url origin | ForEach-Object { $_ -replace 'https://github.com/','' -replace '\.git$','' })/pull/new/$BranchName"
