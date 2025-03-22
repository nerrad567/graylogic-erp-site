<#
.SYNOPSIS
    Fetches, decrypts, expands, and securely manages encrypted backups from a specified domain.
.DESCRIPTION
    This script handles sensitive backup operations with options to fetch, decrypt, and expand files,
    or securely wipe confidential data. It ensures proper error handling, user confirmation, and secure cleanup.
.PARAMETER WipeConfidential
    Switch to securely delete confidential files without running the full backup process.
.EXAMPLE
    .\BackupScript.ps1 -WipeConfidential
    .\BackupScript.ps1
.NOTES
    Author: GL Maintenance
    Date: February 24, 2025
    Requires: Gpg4win, 7-Zip, SDelete, OpenSSH
#>
param (
    [switch]$WipeConfidential
)

# Configuration Variables
$DOMAIN = "[DOMAIN]"              # Replace with your domain (e.g., example.com)
$SSH_USER = "[SSH_USER]"          # Replace with your SSH username
$KEYBASE_USER = "[KEYBASE_USER]"  # Replace with your Keybase username
$USERNAME = "[USERNAME]"          # Replace with your Windows username

# Constants
$BACKUPS_FOLDER = "C:\Users\$USERNAME\backups"  # Remove trailing backslash
$ODOO_FOLDER = Join-Path -Path $BACKUPS_FOLDER -ChildPath "odoo-traefik"  # Use Join-Path for clean path construction
$SDELETE_PATH = Join-Path -Path $BACKUPS_FOLDER -ChildPath "sdelete.exe"
$SEVENZIP_PATH = "C:\Program Files\7-Zip\7z.exe"
$LOG_FILE = Join-Path -Path $BACKUPS_FOLDER -ChildPath "backup_script.log"
$ONEDRIVE_FOLDER = "C:\Users\$USERNAME\OneDrive\Documents\$DOMAIN-Website\backups\docker_configs"

# Utility Functions
function Write-Banner {
    Write-Host "=============================================================" -ForegroundColor Red
    Write-Host " Backup Fetcher & Decryptor" -ForegroundColor Yellow
    Write-Host " WARNING: Handles HIGHLY SENSITIVE DATA from $DOMAIN." -ForegroundColor Red
    Write-Host " Exposure risks customer data and legal consequences." -ForegroundColor Red
    Write-Host " Use -WipeConfidential to securely delete sensitive files." -ForegroundColor Cyan
    Write-Host " Note: On SSDs, secure deletion may be less effective due to TRIM/wear-leveling." -ForegroundColor Cyan
    Write-Host "       For end-of-life, run 'sdelete -z' then physically destroy the drive." -ForegroundColor Cyan
    Write-Host "=============================================================" -ForegroundColor Red
}

function Write-Log {
    param (
        [string]$Message,
        [ConsoleColor]$ForegroundColor = "White"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LOG_FILE -Append
    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Test-Prerequisites {
    if (-not (Test-Path $BACKUPS_FOLDER)) {
        Write-Log "Error: Backups folder '$BACKUPS_FOLDER' not found." -ForegroundColor Red
        Write-Log "Run: New-Item -Path '$BACKUPS_FOLDER' -ItemType Directory" -ForegroundColor Yellow
        Write-Log "Install: Gpg4win, 7-Zip, SDelete, and import public key." -ForegroundColor Cyan
        Write-Log "Key Location: Keybase: https://keybase.io/$KEYBASE_USER/pgp_keys.asc" -ForegroundColor Cyan
        Write-Log "Run: Invoke-WebRequest -Uri 'https://keybase.io/$KEYBASE_USER/pgp_keys.asc' -OutFile '$BACKUPS_FOLDER\$KEYBASE_USER_public_key.asc'" -ForegroundColor Cyan
        Write-Log "Then: gpg --import '$BACKUPS_FOLDER\$KEYBASE_USER_public_key.asc'" -ForegroundColor Cyan
        exit 1
    }
    if (-not (Test-Path $SDELETE_PATH)) {
        Write-Log "Error: SDelete not found at '$SDELETE_PATH'." -ForegroundColor Red
        Write-Log "Download from: https://learn.microsoft.com/en-us/sysinternals/downloads/sdelete" -ForegroundColor Yellow
        exit 1
    }
    if (-not (Test-Path $SEVENZIP_PATH)) {
        Write-Log "Error: 7-Zip not found at '$SEVENZIP_PATH'." -ForegroundColor Red
        Write-Log "Install from: https://www.7-zip.org/" -ForegroundColor Yellow
        exit 1
    }
    try {
        $testFile = "$BACKUPS_FOLDER\test.txt"
        "test" | Out-File $testFile
        Remove-Item $testFile -Force
    }
    catch {
        Write-Log "Error: No write permissions to '$BACKUPS_FOLDER'. Run as Administrator." -ForegroundColor Red
        exit 1
    }
}

function Confirm-Action {
    param ([string]$Message)
    $response = Read-Host "$Message (yes/no)"
    return $response -eq "yes"
}

function Remove-SecureFile {
    param ([string]$Path)
    if (Test-Path $Path) {
        Write-Log "Securely deleting '$Path'..." -ForegroundColor Green
        & $SDELETE_PATH -p 3 -r -s $Path
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Warning: Secure deletion of '$Path' may have failed." -ForegroundColor Yellow
        }
        elseif (Test-Path $Path) {
            Write-Log "Error: '$Path' still exists after secure deletion attempt." -ForegroundColor Red
        }
    }
}

function Remove-ConfidentialFiles {
    Write-Log "Running fail-safe cleanup of confidential files..." -ForegroundColor Yellow
    Get-ChildItem -Path $BACKUPS_FOLDER -Filter "*.gz" | ForEach-Object { 
        if ($_.FullName -ne $decryptedPath) {
            # Avoid double-deletion if already handled
            Remove-SecureFile -Path $_.FullName 
        }
    }
    Get-ChildItem -Path $BACKUPS_FOLDER -Filter "*.tar" | ForEach-Object { 
        Remove-SecureFile -Path $_.FullName 
    }
    Write-Log "Fail-safe cleanup complete. Only '$ODOO_FOLDER' should remain with intended contents." -ForegroundColor Green
}

function Clear-ConfidentialFiles {
    Write-Log "Running in -WipeConfidential mode:" -ForegroundColor Yellow
    Write-Log "Deleting all .gz, .tar, and odoo-traefik contents." -ForegroundColor Cyan
    
    if (Confirm-Action "Proceed with secure wipe?") {
        $deleteFailed = $false
        
        # Delete all .gz files
        $gzFiles = Get-ChildItem -Path $BACKUPS_FOLDER -Filter "*.gz" -ErrorAction SilentlyContinue
        foreach ($file in $gzFiles) {
            Remove-SecureFile -Path $file.FullName
            if (Test-Path $file.FullName) {
                Write-Log "Failed to delete '$($file.FullName)'." -ForegroundColor Red
                $deleteFailed = $true
            }
        }

        # Delete all .tar files
        $tarFiles = Get-ChildItem -Path $BACKUPS_FOLDER -Filter "*.tar" -ErrorAction SilentlyContinue
        foreach ($file in $tarFiles) {
            Remove-SecureFile -Path $file.FullName
            if (Test-Path $file.FullName) {
                Write-Log "Failed to delete '$($file.FullName)'." -ForegroundColor Red
                $deleteFailed = $true
            }
        }

        # Delete odoo-traefik folder and its contents recursively
        if (Test-Path $ODOO_FOLDER) {
            Write-Log "Securely deleting folder '$ODOO_FOLDER' and all contents..." -ForegroundColor Green
            # Ensure path is clean before passing to sdelete
            $cleanOdooFolder = $ODOO_FOLDER.TrimEnd('\')
            & $SDELETE_PATH -p 3 -r -s $cleanOdooFolder
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Warning: Secure deletion of '$cleanOdooFolder' may have failed (exit code: $LASTEXITCODE)." -ForegroundColor Yellow
                $deleteFailed = $true
            }
            if (Test-Path $cleanOdooFolder) {
                Write-Log "Error: '$cleanOdooFolder' still exists after secure deletion attempt." -ForegroundColor Red
                $deleteFailed = $true
            }
            else {
                Write-Log "Folder '$cleanOdooFolder' successfully deleted." -ForegroundColor Green
            }
        }
        else {
            Write-Log "Folder '$ODOO_FOLDER' does not exist; skipping deletion." -ForegroundColor Yellow
        }

        # Report final status
        if (-not $deleteFailed) {
            Write-Log "Confidential files and folder securely deleted." -ForegroundColor Green
        }
        else {
            Write-Log "Some confidential files or the folder could not be deleted. Manual cleanup required." -ForegroundColor Red
        }
    }
    else {
        Write-Log "Wipe cancelled." -ForegroundColor Yellow
    }
    exit 0
}

function Get-BackupFileName {
    do {
        $fileName = Read-Host "Enter encrypted backup file name (e.g., $($DOMAIN)_..._20250224_1514.tar.gz.gpg)"
        if ([string]::IsNullOrEmpty($fileName)) {
            Write-Log "Error: File name cannot be empty." -ForegroundColor Red
        }
        elseif (-not ($fileName -match "\.tar\.gz\.gpg$")) {
            Write-Log "Warning: File should end in .tar.gz.gpg." -ForegroundColor Yellow
            if (-not (Confirm-Action "Proceed anyway?")) {
                $fileName = $null
            }
        }
    } while ([string]::IsNullOrEmpty($fileName))
    return $fileName
}

function Copy-BackupFromRemote {
    param (
        [string]$RemotePath,
        [string]$LocalPath
    )
    if (Test-Path $LocalPath) {
        if (-not (Confirm-Action "Overwrite existing file '$LocalPath'?")) {
            Write-Log "Fetch cancelled." -ForegroundColor Red
            exit 1
        }
    }
    Write-Log "Fetching '$RemotePath' to '$LocalPath'..." -ForegroundColor Green
    Write-Log "SCP will display progress below; this may take a while for large files or slow connections." -ForegroundColor Cyan

    try {
        # Run scp, wait for completion, and capture output
        $scpOutput = Start-Process -FilePath "scp" -ArgumentList "$RemotePath", "$LocalPath" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "scp_output.txt" -RedirectStandardError "scp_error.txt"
        
        # Log scp output
        if (Test-Path "scp_output.txt") {
            Get-Content "scp_output.txt" | ForEach-Object { Write-Log $_ -ForegroundColor Green }
            Remove-Item "scp_output.txt" -Force
        }
        if (Test-Path "scp_error.txt") {
            $errorContent = Get-Content "scp_error.txt"
            if ($errorContent) { throw "SCP error: $errorContent" }
            Remove-Item "scp_error.txt" -Force
        }

        # Check exit code
        if ($scpOutput.ExitCode -ne 0) {
            throw "SCP process failed with exit code $($scpOutput.ExitCode)."
        }

        # Final check with short retry for filesystem lag
        $retryCount = 0
        $maxRetries = 20  # 10 seconds total
        while (-not (Test-Path $LocalPath) -and $retryCount -lt $maxRetries) {
            Start-Sleep -Milliseconds 500
            $retryCount++
            Write-Log "Waiting for '$LocalPath' to appear (attempt $retryCount/$maxRetries)..." -ForegroundColor Yellow
        }
        if (-not (Test-Path $LocalPath)) {
            throw "File not fetched after SCP completion."
        }
        Write-Log "'$LocalPath' confirmed present." -ForegroundColor Green
    }
    catch {
        Write-Log "Error: Fetch failed. $_" -ForegroundColor Red
        Write-Log "Check file name, SSH setup, or network connectivity." -ForegroundColor Yellow
        exit 1
    }
}

function Copy-ToOneDrive {
    param ([string]$Source, [string]$Dest)
    if (Test-Path $Dest) {
        if (-not (Confirm-Action "Overwrite existing file in OneDrive '$Dest'?")) {
            Write-Log "OneDrive copy skipped." -ForegroundColor Yellow
            return
        }
    }
    Write-Log "Copying to OneDrive..." -ForegroundColor Green
    Copy-Item -Path $Source -Destination $Dest -Force
}

function ConvertTo-DecryptedBackup {
    param ([string]$EncryptedPath, [string]$DecryptedPath)
    if (Test-Path $DecryptedPath) {
        if (-not (Confirm-Action "Overwrite existing decrypted file '$DecryptedPath'?")) {
            Write-Log "Decryption cancelled." -ForegroundColor Red
            exit 1
        }
    }
    Write-Log "Decrypting with YubiKey..." -ForegroundColor Green
    try {
        gpg --verbose --output $DecryptedPath --decrypt $EncryptedPath
    }
    catch {
        Write-Log "Error: Decryption failed. $_" -ForegroundColor Red
        Write-Log "Ensure YubiKey is plugged in and key is imported." -ForegroundColor Yellow
        exit 1
    }
}

function Expand-Backup {
    param (
        [string]$ArchivePath,
        [string]$OutputFolder
    )
    Write-Log "Expanding '$ArchivePath' to '$OutputFolder'..." -ForegroundColor Green
    
    # Derive expected .tar file name from .tar.gz (remove .gz)
    $tempTarPath = $ArchivePath -replace '\.gz$', ''
    
    try {
        Write-Log "Extracting .tar.gz to temporary .tar..." -ForegroundColor Green
        Start-Process -FilePath $SEVENZIP_PATH -ArgumentList "x", "$ArchivePath", "-o$OutputFolder", "-y" -Wait -NoNewWindow
        
        # Retry loop to ensure .tar file appears
        $retryCount = 0
        $maxRetries = 5
        while (-not (Test-Path $tempTarPath) -and $retryCount -lt $maxRetries) {
            Start-Sleep -Milliseconds 500
            $retryCount++
            Write-Log "Waiting for '$tempTarPath' to appear (attempt $retryCount/$maxRetries)..." -ForegroundColor Yellow
        }
        if (-not (Test-Path $tempTarPath)) {
            # Fallback: Check for any .tar file in $OutputFolder
            $tarFile = Get-ChildItem -Path $OutputFolder -Filter "*.tar" | Select-Object -First 1
            if ($tarFile) {
                $tempTarPath = $tarFile.FullName
                Write-Log "Detected unexpected .tar file '$tempTarPath' instead." -ForegroundColor Yellow
            }
            else {
                throw "Intermediate .tar file not created after $maxRetries attempts."
            }
        }
        Write-Log "'$tempTarPath' confirmed present." -ForegroundColor Green

        Write-Log "Extracting .tar to final contents..." -ForegroundColor Green
        Start-Process -FilePath $SEVENZIP_PATH -ArgumentList "x", "$tempTarPath", "-o$OutputFolder", "-y" -Wait -NoNewWindow
        
        Write-Log "Securely deleting temporary .tar file..." -ForegroundColor Green
        Remove-SecureFile -Path $tempTarPath
        Write-Log "Securely deleting decrypted .tar.gz file..." -ForegroundColor Green
        Remove-SecureFile -Path $ArchivePath
        Write-Log "Extraction and cleanup complete." -ForegroundColor Green
    }
    catch {
        Write-Log "Error: Expansion failed. $_" -ForegroundColor Red
        
        # Retry cleanup with delay
        $retryCount = 0
        $maxRetries = 3
        while ((Test-Path $tempTarPath -or Test-Path $ArchivePath) -and $retryCount -lt $maxRetries) {
            if (Test-Path $tempTarPath) {
                Write-Log "Emergency cleanup: Securely deleting temporary .tar file..." -ForegroundColor Yellow
                Remove-SecureFile -Path $tempTarPath
                if (Test-Path $tempTarPath) {
                    Write-Log "Critical: Temporary .tar file still exists!" -ForegroundColor Red
                }
            }
            if (Test-Path $ArchivePath) {
                Write-Log "Emergency cleanup: Securely deleting decrypted .tar.gz file..." -ForegroundColor Yellow
                Remove-SecureFile -Path $ArchivePath
                if (Test-Path $ArchivePath) {
                    Write-Log "Critical: Decrypted .tar.gz file still exists!" -ForegroundColor Red
                }
            }
            if (Test-Path $tempTarPath -or Test-Path $ArchivePath) {
                Start-Sleep -Seconds 1
                $retryCount++
                Write-Log "Retrying cleanup (attempt $retryCount/$maxRetries)..." -ForegroundColor Yellow
            }
        }
        # Final check for any stray .tar files
        $strayTarFiles = Get-ChildItem -Path $OutputFolder -Filter "*.tar"
        foreach ($stray in $strayTarFiles) {
            Write-Log "Emergency cleanup: Found stray .tar file '$($stray.FullName)', deleting..." -ForegroundColor Yellow
            Remove-SecureFile -Path $stray.FullName
        }
        if (Test-Path $tempTarPath -or Test-Path $ArchivePath -or $strayTarFiles) {
            Write-Log "Critical: Cleanup incomplete after retries. Manual intervention required." -ForegroundColor Red
        }
        exit 1
    }
}

# Main Execution
Write-Banner
Test-Prerequisites

if ($WipeConfidential) {
    Clear-ConfidentialFiles
}

try {
    $fileName = Get-BackupFileName
    $remotePath = "${SSH_USER}@${DOMAIN}:/home/${SSH_USER}/backups/${fileName}"
    $localPath = Join-Path -Path $BACKUPS_FOLDER -ChildPath $fileName
    $oneDrivePath = Join-Path -Path $ONEDRIVE_FOLDER -ChildPath $fileName
    $decryptedPath = "$BACKUPS_FOLDER\decrypted_backup.tar.gz"

    Copy-BackupFromRemote -RemotePath $remotePath -LocalPath $localPath
    Copy-ToOneDrive -Source $localPath -Dest $oneDrivePath
    ConvertTo-DecryptedBackup -EncryptedPath $localPath -DecryptedPath $decryptedPath
    Expand-Backup -ArchivePath $decryptedPath -OutputFolder $BACKUPS_FOLDER
    Write-Log "Cleanup: Deleting encrypted local backup file '$localPath'..." -ForegroundColor Green
    Remove-Item -Path $localPath -Force
    if (Test-Path $localPath) {
        Write-Log "Warning: Encrypted local backup file '$localPath' still exists!" -ForegroundColor Yellow
    }
}
catch {
    Write-Log "Error: Backup process failed. $_" -ForegroundColor Red
    $retryCount = 0
    $maxRetries = 3
    while ((Test-Path $decryptedPath -or Test-Path $localPath) -and $retryCount -lt $maxRetries) {
        if (Test-Path $decryptedPath) {
            Write-Log "Emergency cleanup: Securely deleting decrypted .tar.gz file..." -ForegroundColor Yellow
            Remove-SecureFile -Path $decryptedPath
            if (Test-Path $decryptedPath) {
                Write-Log "Critical: Decrypted .tar.gz file still exists!" -ForegroundColor Red
            }
        }
        Write-Log "Local Path: '$localPath'..." -ForegroundColor Yellow
        if (Test-Path $localPath) {
            Remove-Item -Path $localPath -Force
            if (Test-Path $localPath) {
                Write-Log "Warning: Encrypted local backup file '$localPath' still exists!" -ForegroundColor Yellow
            }
        }
        if (Test-Path $decryptedPath -or Test-Path $localPath) {
            Start-Sleep -Seconds 1
            $retryCount++
            Write-Log "Retrying cleanup (attempt $retryCount/$maxRetries)..." -ForegroundColor Yellow
        }
    }
    if (Test-Path $decryptedPath -or Test-Path $localPath) {
        Write-Log "Critical: Cleanup incomplete after retries. Manual intervention required." -ForegroundColor Red
    }
    exit 1
}
finally {
    Remove-ConfidentialFiles
}

Write-Log "Process complete. Check '$ODOO_FOLDER' for expanded files." -ForegroundColor Green
Write-Log "CRITICAL: '$ODOO_FOLDER' contains sensitive data. Use -WipeConfidential to delete." -ForegroundColor Red
Write-Log "For end-of-life disposal, run 'sdelete -z C:' then physically destroy the drive." -ForegroundColor Cyan