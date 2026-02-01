param(
    [Parameter(Mandatory=$true)]
    [string]$Server,
    
    [Parameter(Mandatory=$true)]
    [string]$Username,
    
    [Parameter(Mandatory=$false)]
    [string]$Password,
    
    [Parameter(Mandatory=$false)]
    [string]$PasswordBase64,
    
    [Parameter(Mandatory=$true)]
    [string]$TestPath  # AppFolderLocation from deploy.config.json
)

function Convert-LocalPathToUNC {
    param(
        [string]$LocalPath,
        [string]$Server
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

try {
    # Decode password from base64 if provided, otherwise use plain password
    if ($PasswordBase64) {
        $passwordBytes = [System.Convert]::FromBase64String($PasswordBase64)
        $Password = [System.Text.Encoding]::Unicode.GetString($passwordBytes)
    }
    # Create secure string from plain text password
    $SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    
    # Create credential object
    $Credential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)
    
    # Test PowerShell Remoting (simple approach - same as original working script)
    $session = New-PSSession -ComputerName $Server -Credential $Credential -ErrorAction Stop
    
    if ($session) {
        Remove-PSSession $session -ErrorAction SilentlyContinue
        Write-Output "SUCCESS"
        exit 0
    } else {
        Write-Output "FAILED: Could not establish connection to $Server"
        exit 1
    }
    
} catch {
    # Connection failed - provide helpful troubleshooting
    $errorMsg = "Could not establish connection to $Server.`n`n"
    $errorMsg += "Error: $($_.Exception.Message)`n`n"
    $errorMsg += "MOST COMMON ISSUE - Username Format:`n"
    $errorMsg += "  You entered: $Username`n"
    $errorMsg += "  Try adding your domain: DOMAIN\username (e.g., GETHQ\ivan.ristic or CORP\ivan.ristic)`n"
    $errorMsg += "  Or use: username@yourdomain.com`n`n"
    $errorMsg += "Other troubleshooting steps:`n"
    $errorMsg += "1. Verify WinRM is running on $Server`n"
    $errorMsg += "2. Check firewall allows WinRM (ports 5985/5986)`n"
    $errorMsg += "3. Ensure you have admin rights on $Server`n"
    Write-Output "FAILED: $errorMsg"
    exit 1
}
