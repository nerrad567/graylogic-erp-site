<#
.SYNOPSIS
    Fetches, decrypts, expands, and securely manages encrypted backups.
.DESCRIPTION
    This script retrieves the latest encrypted backup starting with a prefix (default: odoo_full_backup_) via SCP by default,
    stores it in an encrypted backups folder, skipping if MD5 matches or appending a label if different.
    With -Decrypt, it lists available encrypted files, prompts the user to select one, decrypts it with GPG, and extracts
    contents using 7-Zip into a working folder. Provides secure cleanup options. Variables are loaded from an external config file.
.PARAMETER WipeConfidential
    Switch to securely delete confidential files from the working folder without affecting encrypted backups.
.PARAMETER Decrypt
    Switch to enable decryption and extraction, prompting the user to select an encrypted file from the backups folder.
.EXAMPLE
    .\ConfidentialBackupRetriever.ps1                            # Fetches the latest remote backup, skips if MD5 matches
    .\ConfidentialBackupRetriever.ps1 -WipeConfidential         # Wipes the working folder
    .\ConfidentialBackupRetriever.ps1 -Decrypt                  # Prompts to decrypt a local encrypted file
.NOTES
    Author: Darren Gray
    Credits: Developed with assistance from ChatGPT and Grok (xAI)
    Date: March 31, 2025
    Requires: Gpg4win, 7-Zip, SDelete, OpenSSH
    Config File: Expected at <ONEDRIVE_FOLDER>\backup_config.env
#>

param (
    [switch]$WipeConfidential,
    [switch]$Decrypt
)

# region Configuration Loading
$CONFIG_NAME = "backup_config.env"

if (-not (Test-Path $CONFIG_NAME)) {
    Write-Host "Error: Config file '$CONFIG_NAME' not found in the script's directory." -ForegroundColor Red
    Write-Host "Please create '$CONFIG_NAME' with the following variables:" -ForegroundColor Yellow
    Write-Host "  ONEDRIVE_FOLDER=<path>         # OneDrive base folder (e.g., C:\Users\<user>\OneDrive\Documents\backups)"
    Write-Host "  SDELETE_PATH=<path>            # Path to sdelete.exe (e.g., C:\Users\<user>\OneDrive\Documents\backups\sdelete.exe)"
    Write-Host "  SEVENZIP_PATH=<path>           # Path to 7z.exe (e.g., C:\Program Files\7-Zip\7z.exe)"
    Write-Host "  REMOTE_HOST=<user@host>        # SSH remote host (e.g., user@domain.com)"
    Write-Host "  REMOTE_BACKUP_DIR=<path>       # Remote backup directory (e.g., /home/user/backups)"
    Write-Host "  BACKUP_PREFIX=<string>         # Prefix for backup files (e.g., odoo_full_backup_)"
    Write-Host "Create this file in the script's directory and rerun the script." -ForegroundColor Yellow
    exit 1
}

$config = @{}
Get-Content $CONFIG_NAME | ForEach-Object {
    if ($_ -match "^\s*([^#=]+?)\s*=\s*(.+?)\s*(?:#.*)?$") {
        $config[$matches[1]] = $matches[2]
    }
}

if (-not $config["ONEDRIVE_FOLDER"]) { Write-Host "Error: ONEDRIVE_FOLDER not set in config" -ForegroundColor Red; exit 1 }
$ONEDRIVE_FOLDER = $config["ONEDRIVE_FOLDER"]
if (-not $config["SDELETE_PATH"]) { Write-Host "Error: SDELETE_PATH not set in config" -ForegroundColor Red; exit 1 }
$SDELETE_PATH = $config["SDELETE_PATH"]
if (-not $config["SEVENZIP_PATH"]) { Write-Host "Error: SEVENZIP_PATH not set in config" -ForegroundColor Red; exit 1 }
$SEVENZIP_PATH = $config["SEVENZIP_PATH"]
if (-not $config["REMOTE_HOST"]) { Write-Host "Error: REMOTE_HOST not set in config" -ForegroundColor Red; exit 1 }
$REMOTE_HOST = $config["REMOTE_HOST"]
if (-not $config["REMOTE_BACKUP_DIR"]) { Write-Host "Error: REMOTE_BACKUP_DIR not set in config" -ForegroundColor Red; exit 1 }
$REMOTE_BACKUP_DIR = $config["REMOTE_BACKUP_DIR"]
if (-not $config["BACKUP_PREFIX"]) { Write-Host "Error: BACKUP_PREFIX not set in config" -ForegroundColor Red; exit 1 }
$BACKUP_PREFIX = $config["BACKUP_PREFIX"]

$WORKING_FOLDER = Join-Path -Path $ONEDRIVE_FOLDER -ChildPath "working"
$ENCRYPTED_BACKUPS_FOLDER = Join-Path -Path $ONEDRIVE_FOLDER -ChildPath "encrypted_backups"

if (-not (Test-Path $WORKING_FOLDER)) {
    New-Item -Path $WORKING_FOLDER -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path $ENCRYPTED_BACKUPS_FOLDER)) {
    New-Item -Path $ENCRYPTED_BACKUPS_FOLDER -ItemType Directory -Force | Out-Null
}

$LOG_FILE = Join-Path -Path $WORKING_FOLDER -ChildPath "backup_script.log"
# endregion

# region Utility Functions
function Write-Banner {
    <#
    .SYNOPSIS
        Displays a warning banner about handling sensitive data.
    #>
    Write-Host "=============================================================" -ForegroundColor Red
    Write-Host " Backup Fetcher & Decryptor" -ForegroundColor Yellow
    Write-Host " WARNING: Handles HIGHLY SENSITIVE DATA from a remote server." -ForegroundColor Red
    Write-Host " Exposure risks sensitive data and legal consequences." -ForegroundColor Red
    Write-Host " Use -WipeConfidential to securely delete sensitive files." -ForegroundColor Cyan
    Write-Host " Note: SSD secure deletion may be less effective (TRIM/wear-leveling)." -ForegroundColor Cyan
    Write-Host "       For end-of-life, run 'sdelete -z' then destroy drive." -ForegroundColor Cyan
    Write-Host "=============================================================" -ForegroundColor Red
}

function Write-Log {
    <#
    .SYNOPSIS
        Logs messages to file and console with timestamp and color.
    #>
    param (
        [string]$Message,
        [ConsoleColor]$ForegroundColor = "White"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LOG_FILE -Append
    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Test-Prerequisites {
    <#
    .SYNOPSIS
        Verifies required tools and permissions are available within OneDrive.
    #>
    if (-not (Test-Path $WORKING_FOLDER)) { Write-Log "Error: Working folder '$WORKING_FOLDER' not found." -ForegroundColor Red; exit 1 }
    if (-not (Test-Path $ENCRYPTED_BACKUPS_FOLDER)) { Write-Log "Error: Encrypted backups folder '$ENCRYPTED_BACKUPS_FOLDER' not found." -ForegroundColor Red; exit 1 }
    if (-not (Test-Path $SDELETE_PATH)) { Write-Log "Error: SDelete not found at '$SDELETE_PATH'." -ForegroundColor Red; exit 1 }
    if (-not (Test-Path $SEVENZIP_PATH)) { Write-Log "Error: 7-Zip not found at '$SEVENZIP_PATH'." -ForegroundColor Red; exit 1 }
    if (-not (Get-Command "gpg" -ErrorAction SilentlyContinue)) { Write-Log "Error: GPG (Gpg4win) not found in PATH." -ForegroundColor Red; exit 1 }
    if (-not (Get-Command "scp" -ErrorAction SilentlyContinue)) { Write-Log "Error: SCP (OpenSSH) not found in PATH." -ForegroundColor Red; exit 1 }
    if (-not (Get-Command "ssh" -ErrorAction SilentlyContinue)) { Write-Log "Error: SSH not found in PATH. Required for listing remote files." -ForegroundColor Red; exit 1 }
    try {
        "test" | Out-File "$WORKING_FOLDER\test.txt" -Force
        Remove-Item "$WORKING_FOLDER\test.txt" -Force
    } catch {
        Write-Log "Error: No write permissions to '$WORKING_FOLDER'. Run as Administrator." -ForegroundColor Red
        exit 1
    }
    try {
        "test" | Out-File "$ENCRYPTED_BACKUPS_FOLDER\test.txt" -Force
        Remove-Item "$ENCRYPTED_BACKUPS_FOLDER\test.txt" -Force
    } catch {
        Write-Log "Error: No write permissions to '$ENCRYPTED_BACKUPS_FOLDER'. Run as Administrator." -ForegroundColor Red
        exit 1
    }
}

function Confirm-Action {
    <#
    .SYNOPSIS
        Prompts user for confirmation.
    #>
    param ([string]$Message)
    $response = Read-Host "$Message (yes/no)"
    return $response -eq "yes"
}

function Remove-SecureFile {
    <#
    .SYNOPSIS
        Securely deletes a file using SDelete.
    #>
    param ([string]$Path)
    if (Test-Path $Path) {
        Write-Log "Securely deleting '$Path'..." -ForegroundColor Green
        & $SDELETE_PATH -p 3 -r -s $Path
        if ($LASTEXITCODE -ne 0 -or (Test-Path $Path)) {
            Write-Log "Warning: Secure deletion of '$Path' may have failed." -ForegroundColor Yellow
        }
    }
}

function Clear-ConfidentialFiles {
    <#
    .SYNOPSIS
        Securely wipes all files and subdirectories in the working directory, preserving the log file.
    #>
    Write-Log "Running -WipeConfidential mode..." -ForegroundColor Yellow
    if (Confirm-Action "Proceed with secure wipe of all contents in '$WORKING_FOLDER' (except log file)?") {
        Get-ChildItem -Path $WORKING_FOLDER -Exclude "backup_script.log" -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-SecureFile -Path $_.FullName
        }
        Write-Log "All confidential files and subdirectories in '$WORKING_FOLDER' wiped (log file preserved)." -ForegroundColor Green
    } else {
        Write-Log "Wipe cancelled." -ForegroundColor Yellow
    }
    exit 0
}

function Get-LatestRemoteBackup {
    <#
    .SYNOPSIS
        Retrieves the latest backup file from the remote directory matching the BACKUP_PREFIX.
    #>
    Write-Log "Fetching list of remote backups from '$REMOTE_HOST`:$REMOTE_BACKUP_DIR'..." -ForegroundColor Green
    $tempFile = Join-Path -Path $WORKING_FOLDER -ChildPath "remote_files.txt"
    $sshCommand = "ls -t $REMOTE_BACKUP_DIR/$BACKUP_PREFIX*.tar.gz.gpg"
    $sshProcess = Start-Process -FilePath "ssh" -ArgumentList "$REMOTE_HOST", "$sshCommand" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $tempFile -RedirectStandardError "$WORKING_FOLDER\ssh_error.txt"
    
    if ($sshProcess.ExitCode -ne 0) {
        $errorContent = Get-Content "$WORKING_FOLDER\ssh_error.txt" -ErrorAction SilentlyContinue
        Write-Log "Error: Failed to list remote files. SSH exit code: $($sshProcess.ExitCode). Error: $errorContent" -ForegroundColor Red
        Remove-Item "$WORKING_FOLDER\ssh_error.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        exit 1
    }
    
    $files = Get-Content $tempFile -ErrorAction SilentlyContinue
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    Remove-Item "$WORKING_FOLDER\ssh_error.txt" -Force -ErrorAction SilentlyContinue
    
    if (-not $files) {
        Write-Log "Error: No files found matching '$BACKUP_PREFIX*.tar.gz.gpg' in '$REMOTE_BACKUP_DIR'." -ForegroundColor Red
        exit 1
    }
    
    # Take the first file (latest due to -t sorting)
    $latestFile = $files | Select-Object -First 1
    $fileName = Split-Path -Leaf $latestFile
    Write-Log "Latest backup identified: '$fileName'" -ForegroundColor Green
    return $fileName
}

function Get-RemoteFileMD5 {
    <#
    .SYNOPSIS
        Retrieves the MD5 hash of a remote file using ssh and md5sum.
    #>
    param ([string]$RemotePath)
    
    $filePath = $RemotePath -replace "^$REMOTE_HOST\:", ""
    Write-Log "Calculating MD5 hash for remote file '$filePath'..." -ForegroundColor Green
    $tempFile = Join-Path -Path $WORKING_FOLDER -ChildPath "remote_md5.txt"
    $sshCommand = "md5sum $filePath"
    $sshProcess = Start-Process -FilePath "ssh" -ArgumentList "$REMOTE_HOST", "$sshCommand" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $tempFile -RedirectStandardError "$WORKING_FOLDER\ssh_error.txt" 
    
    if ($sshProcess.ExitCode -ne 0) {
        $errorContent = Get-Content "$WORKING_FOLDER\ssh_error.txt" -ErrorAction SilentlyContinue
        Write-Log "Error: Failed to get MD5 hash of remote file. SSH exit code: $($sshProcess.ExitCode). Error: $errorContent" -ForegroundColor Red
        Remove-Item "$WORKING_FOLDER\ssh_error.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        exit 1
    }
    
    $md5Output = Get-Content $tempFile -ErrorAction SilentlyContinue
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    Remove-Item "$WORKING_FOLDER\ssh_error.txt" -Force -ErrorAction SilentlyContinue
    
    if ($md5Output -match "^([a-f0-9]{32})") {
        return $matches[1]
    } else {
        Write-Log "Error: Failed to parse MD5 hash from '$md5Output'." -ForegroundColor Red
        exit 1
    }
}

function Get-LocalFileMD5 {
    <#
    .SYNOPSIS
        Calculates the MD5 hash of a local file.
    #>
    param ([string]$LocalPath)
    if (Test-Path $LocalPath) {
        Write-Log "Calculating MD5 hash for local file '$LocalPath'..." -ForegroundColor Green
        $md5 = Get-FileHash -Path $LocalPath -Algorithm MD5
        return $md5.Hash.ToLower()
    }
    return $null
}

function Copy-BackupFromRemote {
    <#
    .SYNOPSIS
        Fetches the backup file from the remote server using SCP, skipping if MD5 matches or appending a note if different.
    #>
    param ([string]$RemotePath)
    $fileName = Split-Path -Leaf $RemotePath
    $localFilePath = Join-Path -Path $ENCRYPTED_BACKUPS_FOLDER -ChildPath $fileName
    
    Write-Log "Checking if '$localFilePath' exists..." -ForegroundColor Cyan
    if (Test-Path $localFilePath) {
        Write-Log "File '$localFilePath' exists." -ForegroundColor Yellow
        $remoteMD5 = Get-RemoteFileMD5 -RemotePath $RemotePath
        $localMD5 = Get-LocalFileMD5 -LocalPath $localFilePath
        
        if ($remoteMD5 -eq $localMD5) {
            Write-Log "MD5 hash match: Remote ($remoteMD5) = Local ($localMD5). Skipping download." -ForegroundColor Green
            return $localFilePath
        } else {
            Write-Log "MD5 hash mismatch: Remote ($remoteMD5) != Local ($localMD5). Downloading with appended note." -ForegroundColor Yellow
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $newFileName = "$([System.IO.Path]::GetFileNameWithoutExtension($fileName))_downloaded_$timestamp$([System.IO.Path]::GetExtension($fileName))"
            $newLocalPath = Join-Path -Path $ENCRYPTED_BACKUPS_FOLDER -ChildPath $newFileName
            
            Write-Log "Fetching '$RemotePath' to '$newLocalPath'..." -ForegroundColor Green
            $scpProcess = Start-Process -FilePath "scp" -ArgumentList "$RemotePath", "$newLocalPath" -Wait -PassThru
            if ($scpProcess.ExitCode -ne 0) {
                Write-Log "Error: SCP failed with exit code $($scpProcess.ExitCode)." -ForegroundColor Red
                exit 1
            }
            Start-Sleep -Milliseconds 500
            if (-not (Test-Path $newLocalPath)) {
                Write-Log "Error: File '$newLocalPath' not found after SCP transfer." -ForegroundColor Red
                exit 1
            }
            Write-Log "Fetch completed successfully. Stored as '$newLocalPath'." -ForegroundColor Green
            return $newLocalPath
        }
    } else {
        Write-Log "No existing file at '$localFilePath'. Downloading..." -ForegroundColor Green
        $scpProcess = Start-Process -FilePath "scp" -ArgumentList "$RemotePath", "$localFilePath" -Wait -PassThru
        if ($scpProcess.ExitCode -ne 0) {
            Write-Log "Error: SCP failed with exit code $($scpProcess.ExitCode)." -ForegroundColor Red
            exit 1
        }
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path $localFilePath)) {
            Write-Log "Error: File '$localFilePath' not found after SCP transfer." -ForegroundColor Red
            exit 1
        }
        Write-Log "Fetch completed successfully. Stored as '$localFilePath'." -ForegroundColor Green
        return $localFilePath
    }
}

function Get-EncryptedBackupToDecrypt {
    <#
    .SYNOPSIS
        Lists encrypted backups in ENCRYPTED_BACKUPS_FOLDER and prompts user to select one for decryption.
    #>
    Write-Log "Listing available encrypted backups in '$ENCRYPTED_BACKUPS_FOLDER'..." -ForegroundColor Green
    $files = Get-ChildItem -Path $ENCRYPTED_BACKUPS_FOLDER -File -Filter "*.tar.gz.gpg" | Sort-Object LastWriteTime -Descending
    
    if (-not $files) {
        Write-Log "Error: No encrypted backup files found in '$ENCRYPTED_BACKUPS_FOLDER'." -ForegroundColor Red
        exit 1
    }
    
    Write-Log "Available encrypted backups:" -ForegroundColor Yellow
    $index = 0
    foreach ($file in $files) {
        Write-Host "$index : $($file.Name) (Last Modified: $($file.LastWriteTime))"
        $index++
    }
    
    do {
        $selection = Read-Host "Enter the number of the file to decrypt (0-$($files.Count - 1))"
        if ($selection -match '^\d+$' -and [int]$selection -ge 0 -and [int]$selection -lt $files.Count) {
            $selectedFile = $files[$selection].Name
            Write-Log "User selected: '$selectedFile'" -ForegroundColor Green
            return $selectedFile
        } else {
            Write-Log "Invalid selection. Please enter a number between 0 and $($files.Count - 1)." -ForegroundColor Red
        }
    } while ($true)
}

function ConvertTo-DecryptedBackup {
    <#
    .SYNOPSIS
        Decrypts the GPG-encrypted backup file.
    #>
    param ([string]$EncryptedPath, [string]$DecryptedPath)
    Write-Log "Checking if '$DecryptedPath' exists..." -ForegroundColor Cyan
    if (Test-Path $DecryptedPath) {
        Write-Log "File '$DecryptedPath' exists. Contents of working folder:" -ForegroundColor Yellow
        Get-ChildItem -Path (Split-Path -Parent $DecryptedPath) -Force | ForEach-Object { Write-Log "  $($_.Name)" -ForegroundColor Yellow }
        if (-not (Confirm-Action "Overwrite existing decrypted file '$DecryptedPath'?")) {
            Write-Log "Decryption cancelled." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Log "No existing file at '$DecryptedPath'." -ForegroundColor Green
    }
    Write-Log "Decrypting '$EncryptedPath' to '$DecryptedPath' with GPG..." -ForegroundColor Green
    gpg --verbose --output $DecryptedPath --decrypt $EncryptedPath
}

function Expand-Backup {
    <#
    .SYNOPSIS
        Extracts the decrypted backup using 7-Zip.
    #>
    param ([string]$ArchivePath, [string]$OutputFolder)
    Write-Log "Expanding '$ArchivePath' to '$OutputFolder'..." -ForegroundColor Green
    $tempTarPath = $ArchivePath -replace '\.gz$', ''
    
    Start-Process -FilePath $SEVENZIP_PATH -ArgumentList "x", "$ArchivePath", "-o$OutputFolder", "-y" -Wait -NoNewWindow
    if (-not (Test-Path $tempTarPath)) {
        Write-Log "Error: Intermediate .tar file not created." -ForegroundColor Red
        throw "Extraction failed"
    }
    
    Start-Process -FilePath $SEVENZIP_PATH -ArgumentList "x", "$tempTarPath", "-o$OutputFolder", "-y" -Wait -NoNewWindow
    
    Remove-SecureFile -Path $tempTarPath
    Remove-SecureFile -Path $ArchivePath
}
# endregion

# region Main Execution
Write-Banner
Test-Prerequisites

if ($WipeConfidential) {
    Clear-ConfidentialFiles
}

try {
    if ($Decrypt) {
        $selectedFile = Get-EncryptedBackupToDecrypt
        $encryptedPath = Join-Path -Path $ENCRYPTED_BACKUPS_FOLDER -ChildPath $selectedFile
        $decryptedPath = Join-Path -Path $WORKING_FOLDER -ChildPath "decrypted_backup.tar.gz"

        ConvertTo-DecryptedBackup -EncryptedPath $encryptedPath -DecryptedPath $decryptedPath
        Expand-Backup -ArchivePath $decryptedPath -OutputFolder $WORKING_FOLDER
        Write-Log "Process complete. Check '$WORKING_FOLDER' for expanded files." -ForegroundColor Green
        Write-Log "Encrypted backup retained at '$encryptedPath'." -ForegroundColor Green
    } else {
        # Default action: Fetch the latest remote backup
        $fileName = Get-LatestRemoteBackup
        $remotePath = "$REMOTE_HOST`:$REMOTE_BACKUP_DIR/$fileName"
        $localPath = Copy-BackupFromRemote -RemotePath $remotePath
        
        Write-Log "Latest backup processed and stored at '$localPath'. Use -Decrypt to proceed with decryption." -ForegroundColor Green
    }
} catch {
    Write-Log "Error: Process failed. $_" -ForegroundColor Red
    if (Test-Path $decryptedPath) { Remove-SecureFile -Path $decryptedPath }
    exit 1
}

if ($Decrypt) {
    Write-Log "CRITICAL: '$WORKING_FOLDER' contains sensitive data. Use -WipeConfidential to delete." -ForegroundColor Red
}
# endregion
