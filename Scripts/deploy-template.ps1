param(
    [string]$Username = "",
    [string]$Password = "",
    [string]$PasswordBase64 = "",
    [string]$Server = "",
    [string]$AppPoolName = "",
    [string]$AppFolderLocation = "",
    [string]$NewFilesPath = "",
    [string]$BackupFolder = "",
    [string[]]$ExcludeFromCleanup = @(),  # Files to preserve in the target folder
    [string[]]$ExcludeFromCopy = @()      # Files to exclude when copying from source
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

    # Convert remote temp path to UNC for fast file copying
    Write-Info "Copying files to remote server..."
    $uncRemoteTemp = Convert-LocalPathToUNC -LocalPath $remoteTemp
    
    # Build robocopy exclude arguments
    # ExcludeFromCopy patterns: treat as directory if no extension or starts with dot
    $excludeDirs = @()
    $excludeFiles = @()
    
    foreach ($pattern in $ExcludeFromCopy) {
        # Remove wildcards for robocopy
        $cleanPattern = $pattern -replace '\*', ''
        
        # Check if pattern looks like a directory (no extension after last part)
        if ($cleanPattern -notmatch '\.[a-zA-Z0-9]+$') {
            # Treat as directory (e.g., "bin", "obj", ".git")
            $excludeDirs += $cleanPattern
        } else {
            # Treat as file (e.g., "web.config", "*.dll")
            $excludeFiles += $pattern
        }
    }
    
    # Build robocopy command arguments
    $robocopyArgs = @(
        $NewFilesPath,
        $uncRemoteTemp,
        "/E",              # Copy subdirectories including empty ones
        "/MT:16",          # Multi-threaded copy (16 threads)
        "/R:2",            # Retry 2 times on failed copies
        "/W:1",            # Wait 1 second between retries
        "/NFL",            # No file list (reduces output)
        "/NDL",            # No directory list
        "/NP"              # No progress percentage
    )
    
    # Add exclude directories
    if ($excludeDirs.Count -gt 0) {
        $robocopyArgs += "/XD"
        $robocopyArgs += $excludeDirs
    }
    
    # Add exclude files
    if ($excludeFiles.Count -gt 0) {
        $robocopyArgs += "/XF"
        $robocopyArgs += $excludeFiles
    }
    
    # Execute robocopy (suppress output)
    $robocopyResult = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\robocopy_out.txt" -RedirectStandardError "$env:TEMP\robocopy_err.txt"
    
    # Robocopy exit codes: 0-7 are success, 8+ are errors
    if ($robocopyResult.ExitCode -ge 8) {
        throw "Robocopy failed with exit code $($robocopyResult.ExitCode)."
    }
    
    $deploymentState.FilesCopied = $true
    Write-Success "Files copied successfully."

    # Execute deployment with detailed state tracking
    $deployResult = Invoke-Command -Session $session -ScriptBlock {
        param($AppPoolName, $AppFolderLocation, $NewFilesPath, $BackupFolder, $ExcludeFromCleanup)

        function Write-Log { 
            param($m) 
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $m" 
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
                Compress-Archive -Path "$AppFolderLocation\*" -DestinationPath $backupPath -Force
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
			$allItems = Get-ChildItem -Path $AppFolderLocation -Recurse
			$preservedItems = @()
			$itemsToRemove = @()

			foreach ($item in $allItems) {
				$shouldPreserve = $false
				foreach ($ex in $ExcludeFromCleanup) {
					# Match exact name or wildcard pattern
					if ($item.Name -like $ex) {
						$shouldPreserve = $true
						$preservedItems += $item
						Write-Log "Preserving item: $($item.Name)"
						break
					}
				}
				
				if (-not $shouldPreserve) {
					$itemsToRemove += $item
				}
			}

			# Remove non-preserved items
			foreach ($item in $itemsToRemove) {
				try {
					if (Test-Path -LiteralPath $item.FullName) {
						Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
					}
				} catch {
					# Only warn if the item still exists (not already removed by parent folder deletion)
					if (Test-Path -LiteralPath $item.FullName) {
						Write-Log "Warning: Could not remove $($item.FullName): $_"
					}
				}
			}


			$result.AppFolderCleaned = $true
			Write-Log "Target folder cleaned."

            # Copy new files
            Write-Log "Deploying new files..."
            Copy-Item "$NewFilesPath\*" -Destination $AppFolderLocation -Recurse -Force
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
    Write-Info "Cleaning remote temp folder..."
    $uncRemoteTempCleanup = Convert-LocalPathToUNC -LocalPath $remoteTemp
    Remove-Item -Path $uncRemoteTempCleanup -Recurse -Force -ErrorAction SilentlyContinue
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
                    Expand-Archive -Path $BackupPath -DestinationPath $AppFolderLocation -Force
                    
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