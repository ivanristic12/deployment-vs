param(
    [string]$Username = "",
    [string]$Password = "",
    [string]$PasswordBase64 = "",
    [string]$Server = "",
    [string]$AppPoolName = "",
    [string]$AppFolderLocation = "",
    [string]$NewFilesPath = "",
    [string]$BackupFolder = "",
    [string]$ExcludeFromCleanup = "",  # Comma-separated list of files to preserve in the target folder
    [string]$ExcludeFromCopy = ""      # Comma-separated list of files to exclude when copying from source
)

#----------------------------Functions---------------------------------------- 
function Convert-LocalPathToUNC {
    param(
        [string]$LocalPath
    )

    # Match drive letter and path using regex
    if ($LocalPath -match "^([a-zA-Z]):\\(.+)$") {
        $driveLetter = $matches[1].ToLower()  # get drive letter, e.g., "c" or "d"
        $restOfPath = $matches[2]             # rest of path after drive letter

        # Construct UNC path using admin share
        $uncPath = "\\$Server\$($driveLetter)`$\$restOfPath"

        return $uncPath
    } else {
        throw "Invalid local path format. Expected format like 'C:\folder\subfolder'"
    }
}

function Write-Info { 
    param(
        [string]$m,
        [string]$color = "White"
    ) 
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $m" -ForegroundColor $color 
}

function Write-Success { param($m) Write-Info $m "Green" }
function Write-Warning { param($m) Write-Info $m "Yellow" }
function Write-Error { param($m) Write-Info $m "Red" }

function Compress-ArchiveCompat {
    param(
        [string]$Path,
        [string]$DestinationPath,
        [switch]$Force
    )
    
    # Try native Compress-Archive first (PowerShell 5.0+)
    if (Get-Command Compress-Archive -ErrorAction SilentlyContinue) {
        Compress-Archive -Path $Path -DestinationPath $DestinationPath -Force:$Force
    }
    else {
        # Fallback to .NET compression for PowerShell 4.0 (Server 2012 R2)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        
        # Remove existing zip if Force is specified
        if ($Force -and (Test-Path $DestinationPath)) {
            Remove-Item $DestinationPath -Force
        }
        
        # Handle wildcard in path (e.g., "C:\Folder\*")
        if ($Path.EndsWith('\*') -or $Path.EndsWith('/*')) {
            $sourcePath = Split-Path $Path -Parent
            [System.IO.Compression.ZipFile]::CreateFromDirectory($sourcePath, $DestinationPath)
        }
        else {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($Path, $DestinationPath)
        }
    }
}

function Expand-ArchiveCompat {
    param(
        [string]$Path,
        [string]$DestinationPath,
        [switch]$Force
    )
    
    # Try native Expand-Archive first (PowerShell 5.0+)
    if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
        Expand-Archive -Path $Path -DestinationPath $DestinationPath -Force:$Force
    }
    else {
        # Fallback to .NET extraction for PowerShell 4.0 (Server 2012 R2)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        
        # .NET ExtractToDirectory requires empty/non-existent directory
        # If Force is specified and directory exists, clear it first
        if ($Force -and (Test-Path $DestinationPath)) {
            Remove-Item -Path $DestinationPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        # Create destination directory if it doesn't exist
        if (-not (Test-Path $DestinationPath)) {
            New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        }
        
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $DestinationPath)
    }
}

#----------------End of functions-------------------------

#---------------------Main--------------------------------------------------------------------
# Define state tracking variables
$deploymentState = @{
    RemoteTempCreated = $false
    FilesCopied = $false
    AppPoolStopped = $false
    BackupCreated = $false
    BackupPath = $null
    OriginalFiles = $null
    AppFolderCleaned = $false
    NewFilesDeployed = $false
}

$session = $null
$remoteTemp = $null

try {
    Write-Success "Parameters set."

    # Decode password from base64 if provided, otherwise use plain password
    if ($PasswordBase64) {
        $passwordBytes = [System.Convert]::FromBase64String($PasswordBase64)
        $Password = [System.Text.Encoding]::Unicode.GetString($passwordBytes)
    }
    Write-Info "Server: $Server"

    # Create credential object from provided username and password
    $SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)
    Write-Success "Credentials prepared."

    Write-Info "Starting deployment..."

    # Validate all parameters before proceeding
    if ([string]::IsNullOrEmpty($AppPoolName)) {
        throw "AppPoolName cannot be empty"
    }
    
    if (!(Test-Path $NewFilesPath)) {
        throw "NewFilesPath does not exist: $NewFilesPath"
    }

    # Create remote session
    Write-Info "Creating remote session to $Server..."
    $session = New-PSSession -ComputerName $Server -Credential $cred -ErrorAction Stop
    if (-not $session) { 
        throw "Failed to create session to $Server. Ensure WinRM is enabled and username format is correct (use DOMAIN\username)." 
    }
    Write-Success "Remote session established."
    
    # Validate app pool and paths on remote server
    Write-Info "Validating app pool and paths on remote server..."
    $validationResults = Invoke-Command -Session $session -ScriptBlock {
        param($AppPoolName, $AppFolderLocation)
        
        $result = @{
            AppPoolExists = $false
            AppFolderExists = $false
            ValidationErrors = @() # Renamed from 'Errors' to avoid potential conflicts
        }
        
        # Check if WebAdministration module is available
        try {
            Import-Module WebAdministration -ErrorAction Stop
        } catch {
            $result.ValidationErrors += "WebAdministration module could not be loaded on server $env:COMPUTERNAME"
            return $result
        }
        
        # Check if app pool exists
        if (Test-Path "IIS:\AppPools\$AppPoolName") {
            $result.AppPoolExists = $true
        } else {
            $result.ValidationErrors += "App pool '$AppPoolName' does not exist on server $env:COMPUTERNAME"
        }
        
        # Check if specified app folder path exists or can be created
        if ([string]::IsNullOrWhiteSpace($AppFolderLocation)) {
            $result.ValidationErrors += "Application folder path is empty or invalid"
            return $result
        }
        
        try {
            $parentFolder = Split-Path -Parent $AppFolderLocation
            
            # Check if parent folder exists
            if (!(Test-Path $parentFolder)) {
                $result.ValidationErrors += "Application folder '$AppFolderLocation' cannot be created because parent folder does not exist on server $env:COMPUTERNAME"
                return $result
            }
            
            # Check if app folder exists
            if (Test-Path $AppFolderLocation) {
                $result.AppFolderExists = $true
            } else {
                # Try to create the folder to test permissions
                try {
                    New-Item -Path $AppFolderLocation -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    $result.AppFolderExists = $true
                    Write-Host "Created application folder '$AppFolderLocation' as it didn't exist"
                } catch {
                    $errorMsg = $_.Exception.Message
                    $result.ValidationErrors += "Cannot create application folder '$AppFolderLocation' due to insufficient permissions on server $env:COMPUTERNAME. Detail: $errorMsg"
                }
            }
        } catch {
            $errorMsg = $_.Exception.Message
            $result.ValidationErrors += "Application folder '$AppFolderLocation' is invalid or inaccessible on server $env:COMPUTERNAME. Detail: $errorMsg"
        }
        
        return $result
    } -ArgumentList $AppPoolName, $AppFolderLocation

    # Provide more user-friendly error messages based on validation results
    if ($validationResults.ValidationErrors.Count -gt 0) {
        $errorMessages = @()
        
        foreach ($errorItem in $validationResults.ValidationErrors) {
            if ($errorItem -like "*empty or invalid*") {
                $errorMessages += "Application folder location is empty or invalid. Please provide a valid path."
            } 
            elseif ($errorItem -like "*parent folder does not exist*") {
                $errorMessages += "Application folder '$AppFolderLocation' cannot be created because the parent directory doesn't exist on server $Server."
            }
            elseif ($errorItem -like "*insufficient permissions*") {
                $errorMessages += "Cannot access or create application folder '$AppFolderLocation' due to insufficient permissions on server $Server."
            }
            elseif ($errorItem -like "*invalid or inaccessible*") {
                $errorMessages += "Application folder '$AppFolderLocation' is invalid or inaccessible on server $Server."
            }
            elseif ($errorItem -like "*App pool*") {
                $errorMessages += $errorItem -replace "$env:COMPUTERNAME", "$Server"
            }
            else {
                $errorMessages += $errorItem
            }
        }
        
        $formattedErrors = $errorMessages -join "`n - "
        throw "Validation failed with the following errors:`n - $formattedErrors"
    }

    if (!$validationResults.AppPoolExists) {
        throw "App pool '$AppPoolName' does not exist on server $Server"
    }

    Write-Success "All paths and app pool validated successfully."

    # Create remote temp folder
    Write-Info "Creating temporary folder on remote server..."
    $timeStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $folderName = "Temp_${AppPoolName}_$timeStamp"

    $remoteTemp = Invoke-Command -Session $session -ScriptBlock {
        param($folderName)
        $desktopPath = [Environment]::GetFolderPath('Desktop')
        $tempPath = Join-Path $desktopPath $folderName
        if (-not (Test-Path $tempPath)) {
            New-Item -Path $tempPath -ItemType Directory | Out-Null
        }
        return $tempPath
    } -ArgumentList $folderName

    $deploymentState.RemoteTempCreated = $true
    Write-Info "Remote temp folder created: $remoteTemp"

    # Try UNC/robocopy first (fast), fallback to Copy-Item if UNC not accessible
    Write-Info "Copying files to remote server..."
    Write-Info "Source path (NewFilesPath): $NewFilesPath"
    Write-Info "Destination (remoteTemp): $remoteTemp"
    $copySucceeded = $false
    
    # Split exclusion string into array for use in both copy methods
    $ExcludeFromCopyArray = if ($ExcludeFromCopy) { 
        $ExcludeFromCopy -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } 
    } else { 
        @() 
    }
    
    if ($ExcludeFromCopyArray.Count -gt 0) {
        Write-Info "Excluding from copy: [$($ExcludeFromCopyArray -join ', ')]"
    }
    
    try {
        # Check if UNC path is accessible
        $uncRemoteTemp = Convert-LocalPathToUNC -LocalPath $remoteTemp
        
        if (Test-Path $uncRemoteTemp -ErrorAction Stop) {
            Write-Info "UNC path accessible - using robocopy for fast transfer..."
            
            # Build robocopy exclude arguments
            $excludeDirs = @()
            $excludeFiles = @()
            
            foreach ($pattern in $ExcludeFromCopyArray) {
                $trimmedPattern = $pattern.Trim()
                # For robocopy: treat patterns as both file and folder exclusions
                # If pattern has extension like .json, it's definitely a file
                # If no extension, could match folders OR files starting with that name
                if ($trimmedPattern -match '\.[a-zA-Z0-9]+$') {
                    # Has extension - exclude as file
                    $excludeFiles += $trimmedPattern
                } else {
                    # No extension - exclude both as folder and as file prefix
                    $excludeDirs += $trimmedPattern
                    $excludeFiles += "$trimmedPattern*"
                }
            }
            
            # Build robocopy command arguments
            # Use /MIR or /E to copy contents (not the folder itself)
            Write-Info "Robocopy source: $NewFilesPath"
            Write-Info "Robocopy destination: $uncRemoteTemp"
            $robocopyArgs = @(
                $NewFilesPath,
                $uncRemoteTemp,
                "/MIR", "/MT:16", "/R:2", "/W:1", "/NP"
            )
            
            if ($excludeDirs.Count -gt 0) {
                $robocopyArgs += "/XD"
                $robocopyArgs += $excludeDirs
            }
            
            if ($excludeFiles.Count -gt 0) {
                $robocopyArgs += "/XF"
                $robocopyArgs += $excludeFiles
            }
            
            # Execute robocopy
            $robocopyResult = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\robocopy_out.txt" -RedirectStandardError "$env:TEMP\robocopy_err.txt"
            
            # Robocopy exit codes: 0-7 are success, 8+ are errors
            if ($robocopyResult.ExitCode -ge 8) {
                $output = Get-Content "$env:TEMP\robocopy_out.txt" -Raw -ErrorAction SilentlyContinue
                Write-Warning "Robocopy failed with exit code $($robocopyResult.ExitCode). Output: $output"
                throw "Robocopy failed"
            }
            
            $copySucceeded = $true
            Write-Success "Files copied successfully with robocopy."
        }
    } catch {
        Write-Warning "UNC/robocopy not available: $_"
        Write-Info "Falling back to PowerShell remoting copy method..."
    }
    
    # Fallback: Use compression-based transfer (much faster than file-by-file)
    if (-not $copySucceeded) {
        Write-Info "Using compression-based transfer method..."
        
        # Create local temp folder for staging files
        $localTempFolder = Join-Path $env:TEMP "Deploy_Staging_$timeStamp"
        $zipPath = Join-Path $env:TEMP "Deploy_$timeStamp.zip"
        
        try {
            New-Item -Path $localTempFolder -ItemType Directory -Force | Out-Null
            
            # Get files to copy, respecting exclusions
            $allFiles = Get-ChildItem -Path $NewFilesPath -Recurse -File
            $fileCount = 0
            
            Write-Info "Preparing files for transfer (filtering exclusions)..."
            foreach ($file in $allFiles) {
                $shouldExclude = $false
                $relativePath = $file.FullName.Substring($NewFilesPath.Length + 1)
                
                foreach ($pattern in $ExcludeFromCopyArray) {
                    $trimmedPattern = $pattern.Trim()
                    # Check if the file name or any folder in path matches the pattern
                    $pathSegments = $relativePath.Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)
                    
                    foreach ($segment in $pathSegments) {
                        if ($segment -like "$trimmedPattern*" -or $segment -eq $trimmedPattern) {
                            $shouldExclude = $true
                            break
                        }
                    }
                    if ($shouldExclude) { break }
                }
                
                if (-not $shouldExclude) {
                    $destPath = Join-Path $localTempFolder $relativePath
                    $destDir = Split-Path $destPath -Parent
                    
                    if (-not (Test-Path $destDir)) {
                        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                    }
                    
                    Copy-Item -Path $file.FullName -Destination $destPath -Force
                    $fileCount++
                }
            }
            
            Write-Info "Staged $fileCount files. Compressing for transfer..."
            
            # Compress the staged files
            Compress-ArchiveCompat -Path "$localTempFolder\*" -DestinationPath $zipPath -Force
            
            $zipSize = (Get-Item $zipPath).Length / 1MB
            Write-Info "Compressed to $([math]::Round($zipSize, 2)) MB"
            
            # Transfer single zip file to remote temp
            $remoteZipPath = Join-Path $remoteTemp "deploy.zip"
            Write-Info "Transferring compressed file to remote server..."
            Copy-Item -Path $zipPath -Destination $remoteZipPath -ToSession $session -Force
            
            # Extract on remote server
            Write-Info "Extracting files on remote server..."
            Invoke-Command -Session $session -ScriptBlock {
                param($zipPath, $destFolder)
                
                # Use fallback for PowerShell 4.0+ support
                if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
                    Expand-Archive -Path $zipPath -DestinationPath $destFolder -Force
                }
                else {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    if (-not (Test-Path $destFolder)) {
                        New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
                    }
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $destFolder)
                }
                
                Remove-Item -Path $zipPath -Force
            } -ArgumentList $remoteZipPath, $remoteTemp
            
            Write-Success "Files transferred successfully using compression (1 file vs $fileCount individual files)."
            
        } finally {
            # Clean up local temp files
            if (Test-Path $localTempFolder) {
                Remove-Item -Path $localTempFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path $zipPath) {
                Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    $deploymentState.FilesCopied = $true

    # Execute deployment with detailed state tracking
    $deployResult = Invoke-Command -Session $session -ScriptBlock {
        param($AppPoolName, $AppFolderLocation, $NewFilesPath, $BackupFolder, [string]$ExcludeFromCleanup)

        function Write-Log { 
            param($m) 
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $m" 
        }
        
        # Split the comma-separated string into array HERE in the scriptblock
        $ExcludeArray = if ($ExcludeFromCleanup) { 
            $ExcludeFromCleanup -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } 
        } else { 
            @() 
        }

        # Return object to track deployment state
        $result = @{
            Success = $false
            AppPoolStopped = $false
            BackupCreated = $false
            BackupPath = $null
            AppFolderCleaned = $false
            OriginalAppPoolState = $null
            ErrorMsg = $null
        }

        try {
            Import-Module WebAdministration -ErrorAction Stop
            Write-Log "Loaded WebAdministration module."

            # Check if AppPool exists again (for safety)
            if (!(Test-Path "IIS:\AppPools\$AppPoolName")) {
                throw "App pool '$AppPoolName' does not exist."
            }

            # Get and store original app pool state
            $state = (Get-WebAppPoolState -Name $AppPoolName).Value
            $result.OriginalAppPoolState = $state
            Write-Log "App pool initial state: $state"

            # Stop app pool
            if ($state -ne 'Stopped') {
                Write-Log "Stopping app pool..."
                Stop-WebAppPool -Name $AppPoolName
                Start-Sleep 2
                $result.AppPoolStopped = $true
            } else {
                Write-Log "App pool already stopped."
                $result.AppPoolStopped = $true
            }

            # Create backup folder if it doesn't exist
            if (-not (Test-Path $BackupFolder)) {
                New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null
                Write-Log "Created backup folder."
            }

            # Create backup
            $date = (Get-Date).ToString('yyyyMMdd_HHmmss')
            $backupFileName = "Backup_${AppPoolName}_$date.zip"
            $backupPath = Join-Path $BackupFolder $backupFileName
            
            # Check if app folder exists and has content
            if (!(Test-Path $AppFolderLocation)) {
                New-Item -Path $AppFolderLocation -ItemType Directory -Force | Out-Null
                Write-Log "Created application folder as it didn't exist."
            }
            
            $hasContent = (Get-ChildItem -Path $AppFolderLocation -Force).Count -gt 0
            
            if ($hasContent) {
                Write-Log "Creating backup at: $backupPath"
                
                # Use fallback for PowerShell 4.0+ support
                if (Get-Command Compress-Archive -ErrorAction SilentlyContinue) {
                    Compress-Archive -Path "$AppFolderLocation\*" -DestinationPath $backupPath -Force
                }
                else {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    if (Test-Path $backupPath) { Remove-Item $backupPath -Force }
                    [System.IO.Compression.ZipFile]::CreateFromDirectory($AppFolderLocation, $backupPath)
                }
                
                $result.BackupCreated = $true
                $result.BackupPath = $backupPath
				Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Backup created successfully." -ForegroundColor "Green" 
            } else {
                Write-Log "App folder is empty, no backup needed."
                $result.BackupCreated = $true
                $result.BackupPath = "None - folder was empty"
            }
			
			# Clean target folder, respecting exclusions
			Write-Log "Cleaning target folder..."
			
			if ($ExcludeArray.Count -gt 0) {
				Write-Log "Files/folders to preserve: $($ExcludeArray -join ', ')"
			} else {
				Write-Log "No exclusions - ALL files will be removed"
			}
			
			$allItems = Get-ChildItem -Path $AppFolderLocation -Force

			# Find all items that match exclusion patterns (direct children only)
			foreach ($item in $allItems) {
				$shouldKeep = $false
				
				if ($ExcludeArray.Count -gt 0) {
					foreach ($ex in $ExcludeArray) {
						$pattern = $ex.Trim()
						if ($item.Name -eq $pattern -or $item.Name -like "$pattern*") {
							$shouldKeep = $true
							Write-Log "Preserving: $($item.Name)"
							break
						}
					}
				}
				
				if (-not $shouldKeep) {
					try {
						if (Test-Path -LiteralPath $item.FullName) {
							Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
						}
					} catch {
						Write-Log "Warning: Could not remove $($item.Name): $_"
					}
				}
			}

			$result.AppFolderCleaned = $true
			Write-Log "Target folder cleaned."

            # Copy new files
            Write-Log "Deploying new files..."
            # Ensure we copy contents, not the folder itself
            if ($NewFilesPath.EndsWith('\')) {
                Copy-Item "$($NewFilesPath)*" -Destination $AppFolderLocation -Recurse -Force
            } else {
                Copy-Item "$NewFilesPath\*" -Destination $AppFolderLocation -Recurse -Force
            }
            Write-Log "New files deployed."

            # Start app pool
            Write-Log "Starting app pool..."
            Start-WebAppPool -Name $AppPoolName
            Start-Sleep 2
            
            # Verify app pool started correctly
            $newState = (Get-WebAppPoolState -Name $AppPoolName).Value
            if ($newState -eq 'Started') {
                Write-Log "App pool started successfully."
            } else {
                Write-Log "Warning: App pool is in state '$newState' after starting."
            }

            $result.Success = $true
            Write-Log "Deployment completed successfully."
            return $result

        } catch {
            $result.ErrorMsg = $_.Exception.Message
            Write-Log "Error during deployment: $_"
            return $result
        }
    } -ArgumentList $AppPoolName, $AppFolderLocation, $remoteTemp, $BackupFolder, $ExcludeFromCleanup

    # Update deployment state based on remote results
    $deploymentState.AppPoolStopped = $deployResult.AppPoolStopped
    $deploymentState.BackupCreated = $deployResult.BackupCreated
    $deploymentState.BackupPath = $deployResult.BackupPath
    $deploymentState.AppFolderCleaned = $deployResult.AppFolderCleaned
    $deploymentState.NewFilesDeployed = $deployResult.Success

    # Check deployment result
    if (!$deployResult.Success) {
        throw "Deployment failed on remote server: $($deployResult.ErrorMsg)"
    }

    # Clean up remote temp folder
    Write-Info "Cleaning up remote temp folder..."
    Invoke-Command -Session $session -ScriptBlock {
        param($tempPath)
        if (Test-Path $tempPath) {
            Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $remoteTemp
    Write-Success "Remote temp folder cleaned up."
    $deploymentState.RemoteTempCreated = $false

    Write-Success "Deployment finished successfully."
}
catch {
    Write-Error "Deployment failed: $_"
    
    # Perform rollback based on what steps completed
    if ($session -ne $null) {
        Write-Warning "Starting rollback process..."
        
        # Rollback: If new files were deployed and backup exists, restore from backup
        if ($deploymentState.BackupCreated -and $deploymentState.BackupPath -ne $null -and $deploymentState.BackupPath -ne "None - folder was empty") {
            Write-Info "Restoring from backup: $($deploymentState.BackupPath)"
            
            Invoke-Command -Session $session -ScriptBlock {
                param($AppPoolName, $AppFolderLocation, $BackupPath)
                
                function Write-Log { param($m) Write-Host "ROLLBACK: $m" }
                
                try {
                    # Ensure app pool is stopped for restore
                    Import-Module WebAdministration
                    $state = (Get-WebAppPoolState -Name $AppPoolName).Value
                    if ($state -ne 'Stopped') {
                        Write-Log "Stopping app pool for restore..."
                        Stop-WebAppPool -Name $AppPoolName
                        Start-Sleep 2
                    }
                    
                    # Clean folder before restore (keeping exclusions is too complex for rollback)
                    Write-Log "Cleaning folder for restore..."
                    Get-ChildItem -Path $AppFolderLocation -Recurse | ForEach-Object {
                        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    
                    # Restore from backup
                    Write-Log "Extracting backup..."
                    
                    # Use fallback for PowerShell 4.0+ support
                    if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
                        Expand-Archive -Path $BackupPath -DestinationPath $AppFolderLocation -Force
                    }
                    else {
                        Add-Type -AssemblyName System.IO.Compression.FileSystem
                        if (-not (Test-Path $AppFolderLocation)) {
                            New-Item -Path $AppFolderLocation -ItemType Directory -Force | Out-Null
                        }
                        [System.IO.Compression.ZipFile]::ExtractToDirectory($BackupPath, $AppFolderLocation)
                    }
                    
                    # Restart app pool
                    Write-Log "Restarting app pool..."
                    Start-WebAppPool -Name $AppPoolName
                    
                    Write-Log "Restore completed."
                } catch {
                    Write-Log "Error during rollback: $_"
                }
            } -ArgumentList $AppPoolName, $AppFolderLocation, $deploymentState.BackupPath
        }
        
        # Rollback: Delete remote temp folder if it was created
        if ($deploymentState.RemoteTempCreated -and $remoteTemp) {
            Write-Info "Removing temporary folder..."
            try {
                $uncRemoteTempRollback = Convert-LocalPathToUNC -LocalPath $remoteTemp
                Remove-Item -Path $uncRemoteTempRollback -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                # Ignore errors during rollback cleanup
            }
        }
        
        # Rollback: Ensure app pool is in its original state
        if ($deploymentState.AppPoolStopped) {
            Write-Info "Ensuring app pool is running..."
            Invoke-Command -Session $session -ScriptBlock {
                param($AppPoolName, $OriginalState)
                try {
                    Import-Module WebAdministration
                    $currentState = (Get-WebAppPoolState -Name $AppPoolName).Value
                    
                    # If original state was Running, make sure it's running now
                    if ($OriginalState -eq "Started" -and $currentState -ne "Started") {
                        Start-WebAppPool -Name $AppPoolName
                    }
                } catch {
                    Write-Host "Error restoring app pool state: $_" -ForegroundColor Red
                }
            } -ArgumentList $AppPoolName, $deployResult.OriginalAppPoolState
        }
        
        Write-Warning "Rollback process completed."
    }
}
finally {
    if ($session) {
        Remove-PSSession $session
        Write-Info "Remote session closed."
    }
}
#------------------------------------------------end main----------------------------------