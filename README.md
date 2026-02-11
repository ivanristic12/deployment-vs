# Deploy to IIS for Visual Studio

A powerful Visual Studio extension that simplifies deployment of .NET applications to IIS servers using PowerShell remoting.

## Features

- **One-Click Deployment** - Deploy directly from Solution Explorer with a right-click
- **Secure Authentication** - Test credentials before deployment
- **Real-Time Output** - Monitor deployment progress in the Output window
- **Smart Build Detection** - Automatically detects and builds .NET Framework and .NET 6+ projects
- **Configuration Management** - Support for multiple deployment environments
- **Background Processing** - Non-blocking deployments that keep Visual Studio responsive
- **Backup & Rollback** - Automatic backup of existing files before deployment

## Installation

1. Download the `.vsix` file from the releases
2. Double-click to install in Visual Studio 2022
3. Restart Visual Studio if prompted

## Quick Start

### 1. Create Configuration File

Right-click on your project in Solution Explorer and select **"Deploy to IIS"**. If `deploy.config.json` doesn't exist, the extension will prompt you to create it.

### 2. Configure Deployment Settings

Edit the `deploy.config.json` file in your project root:

```json
{
  "server": "your-server-name",
  "poolName": "YourAppPool",
  "appFolderLocation": "C:\\inetpub\\wwwroot\\YourApp",
  "backupFolderLocation": "C:\\Backups\\YourApp",
  "excludeFromCleanup": ["Logs", "appsettings", "web.config"],
  "excludeFromCopy": ["appsettings"]
}
```

### 3. Deploy

1. Right-click on your project
2. Select **"Deploy to IIS"**
3. Enter your credentials and optionally a configuration name
4. Monitor progress in the Output window

## Configuration Reference

### deploy.config.json

| Property | Description | Example |
|----------|-------------|---------|
| `server` | Target server hostname or IP | `"web-server-01"` |
| `poolName` | IIS Application Pool name | `"MyAppPool"` |
| `appFolderLocation` | Target deployment folder on server | `"C:\\inetpub\\wwwroot\\MyApp"` |
| `backupFolderLocation` | Backup location on server | `"C:\\Backups\\MyApp"` |
| `excludeFromCleanup` | Array of files/folders to preserve during cleanup | startsWith name patter `["Logs", "web.config", "appsettings.json"]` |
| `excludeFromCopy` | Array of files/folders to exclude from deployment | starstWith name pattern `["appsettings"]` |

### Environment-Specific Configurations

You can create environment-specific config files for different deployment targets:

- `deploy.config.json` - Default configuration (used when Configuration field is empty or specified config doesn't exist)
- `deploy.prod.config.json` - Production environment
- `deploy.staging.config.json` - Staging environment
- `deploy.dev.config.json` - Development environment

**How it works:**

1. **Empty Configuration Field**: If you leave the Configuration field empty in the dialog, `deploy.config.json` will be used.

2. **Specific Configuration**: Enter a configuration name (e.g., "prod") in the Configuration field, and the extension will look for `deploy.prod.config.json`. 

3. **Fallback Behavior**: If you enter a configuration name that doesn't have a corresponding file (e.g., "test" but no `deploy.test.config.json`), the extension will automatically fall back to using `deploy.config.json`.

**Examples:**
- Leave Configuration empty → uses `deploy.config.json`
- Enter "prod" → uses `deploy.prod.config.json` (if exists) or `deploy.config.json` (fallback)
- Enter "staging" → uses `deploy.staging.config.json` (if exists) or `deploy.config.json` (fallback)

## Prerequisites

### Server Requirements

1. **Windows Server** with IIS installed
2. **PowerShell Remoting** enabled:
   ```powershell
   Enable-PSRemoting -Force
   ```
3. **WinRM** configured and running
4. **Network access** from your development machine to the server

### Permissions

- User must have administrative rights on the target server
- User must be able to:
  - Stop/Start IIS Application Pools
  - Read/Write to deployment directories
  - Create remote PowerShell sessions

## How It Works

1. **Credential Validation** - Tests remote connection and credentials
2. **Project Publish** - Publishes the project with a clean build (deletes old output first)
3. **Deployment Process**:
   - Creates remote PowerShell session
   - Stops the target application pool
   - Creates backup of existing files
   - Cleans target folder (preserving excluded files)
   - Copies new files to server
   - Starts the application pool
   - Validates deployment

## Build and Publish

The extension automatically performs a **clean publish** every time:

1. **Deletes** the previous publish folder to ensure fresh output
2. **Rebuilds** the entire project from scratch with `--force` flag
3. **Publishes** all files with today's timestamps
4. **Includes** all runtime dependencies needed for deployment

This ensures you always deploy the latest code with no stale files.

## Supported Project Types

- ✅ .NET 6, 7, 8, 9, 10+ (SDK-style projects)
- ✅ .NET Core 3.1
- ✅ ASP.NET Core Web APIs
- ✅ ASP.NET Core MVC Applications
- ✅ .NET Framework 4.x Web Applications
- ❌ Class Libraries (deploy option hidden)

## Troubleshooting

### "Credential validation failed"

- Verify WinRM is running on the target server: `Test-WSMan <server-name>`
- Check firewall rules allow WinRM (ports 5985/5986)
- Use domain credentials without: `username`

### "Build failed"

- Ensure the project builds successfully in Visual Studio
- Check the Output window for detailed error messages
- Verify .NET SDK is installed for the target framework

### "Access Denied"

- Verify user has administrative rights on the server
- Check folder permissions on target directories
- Ensure the application pool identity has proper permissions

## Output Window

Monitor deployment progress in Visual Studio:
1. Go to **View → Output**
2. Select **"Deploy to IIS"** from the dropdown

All deployment steps, messages, and errors are logged here in real-time.

## License

MIT License - see LICENSE.txt for details

## Author

**Ivan Ristic**

## Support

For issues, questions, or contributions, please visit the project repository.

## Version History

### 1.0.0
- Initial release
- Support for .NET Framework and .NET 6+ projects
- Configuration-based deployment
- Real-time output streaming
- Automatic backup and rollback support
