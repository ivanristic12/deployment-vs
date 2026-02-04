using System;
using System.ComponentModel.Design;
using System.IO;
using System.Reflection;
using System.Security;
using System.Linq;
using System.Text;
using Microsoft.VisualStudio.Shell;
using Microsoft.VisualStudio.Shell.Interop;
using Task = System.Threading.Tasks.Task;
using EnvDTE;
using EnvDTE80;
using IISDeployExtension.Dialogs;
using IISDeployExtension.Services;
using IISDeployExtension.Models;

namespace IISDeployExtension
{
    internal sealed class DeployToIISCommand
    {
        public const int CommandId = 0x0100;
        public static readonly Guid CommandSet = new Guid("b2c3d4e5-6f78-90ab-cdef-123456789abc");

        private readonly AsyncPackage package;
        private DTE2 dte;
        private IVsOutputWindowPane outputPane;

        private DeployToIISCommand(AsyncPackage package, OleMenuCommandService commandService)
        {
            this.package = package ?? throw new ArgumentNullException(nameof(package));
            commandService = commandService ?? throw new ArgumentNullException(nameof(commandService));

            var menuCommandID = new CommandID(CommandSet, CommandId);
            var menuItem = new OleMenuCommand(this.Execute, menuCommandID);
            menuItem.BeforeQueryStatus += MenuItem_BeforeQueryStatus;
            commandService.AddCommand(menuItem);
        }

        public static DeployToIISCommand Instance { get; private set; }

        private Microsoft.VisualStudio.Shell.IAsyncServiceProvider ServiceProvider => this.package;

        public static async Task InitializeAsync(AsyncPackage package)
        {
            await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync(package.DisposalToken);

            OleMenuCommandService commandService = await package.GetServiceAsync(typeof(IMenuCommandService)) as OleMenuCommandService;
            Instance = new DeployToIISCommand(package, commandService);
        }

        private void MenuItem_BeforeQueryStatus(object sender, EventArgs e)
        {
            ThreadHelper.ThrowIfNotOnUIThread();
            
            var menuCommand = sender as OleMenuCommand;
            if (menuCommand == null) return;

            // Only show for runnable projects (not class libraries)
            var project = GetSelectedProject();
            if (project != null && IsRunnableProject(project))
            {
                menuCommand.Visible = true;
                menuCommand.Enabled = true;
            }
            else
            {
                menuCommand.Visible = false;
                menuCommand.Enabled = false;
            }
        }

        private void Execute(object sender, EventArgs e)
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            try
            {
                var project = GetSelectedProject();
                if (project == null)
                {
                    ShowMessage("Error", "No project selected.");
                    return;
                }

                string projectDir = GetProjectDirectory(project);
                string configPath = Path.Combine(projectDir, "deploy.config.json");

                if (!File.Exists(configPath))
                {
                    // Ask user if they want to create the config file
                    var createResult = System.Windows.MessageBox.Show(
                        "deploy.config.json not found in project root.\n\nWould you like to create it now?",
                        "Create Configuration File",
                        System.Windows.MessageBoxButton.YesNo,
                        System.Windows.MessageBoxImage.Question);

                    if (createResult == System.Windows.MessageBoxResult.Yes)
                    {
                        CreateDefaultConfigFile(configPath);
                        
                        // Open the file in editor
                        dte.ItemOperations.OpenFile(configPath, EnvDTE.Constants.vsViewKindTextView);
                        
                        ShowMessage("Success", "deploy.config.json has been created.\n\nPlease configure the settings and try again.");
                    }
                    return;
                }

                // Read configuration
                var config = ConfigurationReader.ReadConfiguration(configPath);

                // Get test script path
                string assemblyLocation = Assembly.GetExecutingAssembly().Location;
                string extensionDir = Path.GetDirectoryName(assemblyLocation);
                string testScriptPath = Path.Combine(extensionDir, "Scripts", "test-credentials.ps1");

                if (!File.Exists(testScriptPath))
                {
                    ShowMessage("Error", $"Test script not found at: {testScriptPath}");
                    return;
                }

                // Initialize executor
                var executor = new PowerShellExecutor();
                string username = null;
                string password = null;
                string configuration = null;

                // Show credentials dialog with validation callback
                var dialog = new CredentialsDialog("", (user, pass, conf) =>
                {
                    try
                    {
                        // Determine which config file to use
                        string configFileToUse = configPath; // Default: deploy.config.json
                        
                        if (!string.IsNullOrWhiteSpace(conf))
                        {
                            // User entered a configuration name (e.g., "prod")
                            // Try to find deploy.{conf}.config.json
                            string specificConfigPath = Path.Combine(projectDir, $"deploy.{conf}.config.json");
                            
                            if (File.Exists(specificConfigPath))
                            {
                                // Use the specific config file
                                configFileToUse = specificConfigPath;
                                config = ConfigurationReader.ReadConfiguration(configFileToUse);
                                System.Windows.MessageBox.Show(
                                    $"Using configuration file: {Path.GetFileName(configFileToUse)}",
                                    "Configuration Selected",
                                    System.Windows.MessageBoxButton.OK,
                                    System.Windows.MessageBoxImage.Information);
                            }
                            else
                            {
                                // Configuration doesn't exist, fall back to deploy.config.json
                                configFileToUse = configPath;
                                config = ConfigurationReader.ReadConfiguration(configFileToUse);
                                System.Windows.MessageBox.Show(
                                    $"Configuration '{conf}' not found.\nFile 'deploy.{conf}.config.json' does not exist.\n\nUsing default: deploy.config.json",
                                    "Configuration Fallback",
                                    System.Windows.MessageBoxButton.OK,
                                    System.Windows.MessageBoxImage.Warning);
                            }
                        }
                        else
                        {
                            // Empty configuration, use default deploy.config.json
                            configFileToUse = configPath;
                            config = ConfigurationReader.ReadConfiguration(configFileToUse);
                        }
                        
                        // Test credentials using config values
                        var testResult = executor.TestCredentials(
                            testScriptPath,
                            config.Server,
                            user,
                            ConvertToSecureString(pass),
                            config.AppFolderLocation);

                        if (!testResult.Success)
                        {
                            var errorMsg = testResult.GetErrors();
                            if (string.IsNullOrWhiteSpace(errorMsg))
                            {
                                errorMsg = "Unknown authentication error occurred.";
                            }
                            
                            System.Windows.MessageBox.Show(
                                $"Credential validation failed:\n\n{errorMsg}",
                                "Authentication Failed",
                                System.Windows.MessageBoxButton.OK,
                                System.Windows.MessageBoxImage.Error);
                            return false;
                        }

                        // Store credentials for later use
                        username = user;
                        password = pass;
                        configuration = conf;
                        return true;
                    }
                    catch (Exception ex)
                    {
                        System.Windows.MessageBox.Show(
                            $"Validation error: {ex.Message}",
                            "Error",
                            System.Windows.MessageBoxButton.OK,
                            System.Windows.MessageBoxImage.Error);
                        return false;
                    }
                });

                bool? result = dialog.ShowDialog();

                if (result != true)
                {
                    // User cancelled
                    return;
                }

                // Credentials validated, now build and deploy
                ActivateOutputWindow();
                WriteOutput("========================================");
                WriteOutput("Credentials validated successfully!");
                WriteOutput($"Configuration: {configuration}");
                WriteOutput("========================================");

                // Publish the project
                WriteOutput("\nPublishing project...");
                string buildOutputPath = BuildProject(project, configuration);

                if (string.IsNullOrEmpty(buildOutputPath))
                {
                    ShowMessage("Error", "Publish failed. Check the Output window for details.");
                    return;
                }

                WriteOutput($"Publish completed successfully!");
                WriteOutput($"Output path: {buildOutputPath}");

                // Deploy using the template script
                WriteOutput("\n========================================");
                WriteOutput("Starting deployment...");
                WriteOutput("========================================\n");

                string deployScriptPath = Path.Combine(extensionDir, "Scripts", "deploy-template.ps1");

                if (!File.Exists(deployScriptPath))
                {
                    ShowMessage("Error", $"Deploy script not found at: {deployScriptPath}");
                    return;
                }

                // Run deployment on background thread with real-time output
                System.Threading.Tasks.Task.Run(() =>
                {
                    var deployResult = executor.ExecuteDeploy(
                        deployScriptPath,
                        config.Server,
                        username,
                        ConvertToSecureString(password),
                        config.PoolName,
                        config.AppFolderLocation,
                        buildOutputPath,
                        config.BackupFolderLocation,
                        config.ExcludeFromCleanup,
                        config.ExcludeFromCopy,
                        (line) =>
                        {
                            // Output each line as it comes from PowerShell
                            ThreadHelper.JoinableTaskFactory.Run(async () =>
                            {
                                await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
                                WriteOutput(line);
                            });
                        });

                    // Show final result on UI thread
                    ThreadHelper.JoinableTaskFactory.Run(async () =>
                    {
                        await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();

                        if (deployResult.Success)
                        {
                            WriteOutput("\n========================================");
                            WriteOutput("DEPLOYMENT COMPLETED SUCCESSFULLY!");
                            WriteOutput("========================================");
                        }
                        else
                        {
                            WriteOutput("\n========================================");
                            WriteOutput("DEPLOYMENT FAILED!");
                            WriteOutput("========================================");
                            if (!string.IsNullOrEmpty(deployResult.GetErrors()))
                            {
                                WriteOutput(deployResult.GetErrors());
                            }
                            ShowMessage("Error", $"Deployment failed. Check the Output window for details.");
                        }
                    });
                });

                WriteOutput("\nDeployment is running in background...");
                WriteOutput("You can continue working in Visual Studio.");
            }
            catch (Exception ex)
            {
                ShowMessage("Error", $"Deployment failed: {ex.Message}");
            }
        }

        private bool IsRunnableProject(Project project)
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            try
            {
                // Check OutputType property
                var outputType = project.Properties?.Item("OutputType")?.Value?.ToString();
                if (outputType != null)
                {
                    // 0 = WinExe, 1 = Exe, 2 = Library
                    if (outputType == "0" || outputType == "1" || 
                        outputType.Equals("Exe", StringComparison.OrdinalIgnoreCase) || 
                        outputType.Equals("WinExe", StringComparison.OrdinalIgnoreCase))
                    {
                        return true;
                    }
                }

                // For SDK-style projects, check the project file
                string projectFile = project.FileName;
                if (IsSdkStyleProject(projectFile))
                {
                    string content = File.ReadAllText(projectFile);
                    // Check for <OutputType>Exe</OutputType> or web SDK
                    if (content.Contains("<OutputType>Exe</OutputType>") ||
                        content.Contains("<OutputType>WinExe</OutputType>") ||
                        content.Contains("Microsoft.NET.Sdk.Web"))
                    {
                        return true;
                    }
                }

                return false;
            }
            catch
            {
                // If we can't determine, show the menu
                return true;
            }
        }

        private void CreateDefaultConfigFile(string configPath)
        {
            var defaultConfig = new
            {
                server = "",
                poolName = "",
                appFolderLocation = "",
                backupFolderLocation = "",
                excludeFromCleanup = "",
                excludeFromCopy = ""
            };

            string json = System.Text.Json.JsonSerializer.Serialize(defaultConfig, new System.Text.Json.JsonSerializerOptions
            {
                WriteIndented = true
            });

            File.WriteAllText(configPath, json);
        }

        private Project GetSelectedProject()
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            if (dte == null)
            {
                dte = ThreadHelper.JoinableTaskFactory.Run(async () => 
                    await ServiceProvider.GetServiceAsync(typeof(DTE)) as DTE2);
            }

            if (dte?.SelectedItems == null) return null;

            foreach (SelectedItem item in dte.SelectedItems)
            {
                if (item.Project != null)
                {
                    return item.Project;
                }
                
                // Handle project items (files in project)
                if (item.ProjectItem?.ContainingProject != null)
                {
                    return item.ProjectItem.ContainingProject;
                }
            }

            return null;
        }

        private string GetProjectDirectory(Project project)
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            try
            {
                string fullPath = project.Properties.Item("FullPath").Value.ToString();
                return Path.GetDirectoryName(fullPath);
            }
            catch
            {
                // Fallback: try to get from FileName
                try
                {
                    return Path.GetDirectoryName(project.FileName);
                }
                catch
                {
                    return null;
                }
            }
        }

        private string BuildProject(Project project, string configuration)
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            try
            {
                string projectDir = GetProjectDirectory(project);
                string projectFile = project.FileName;
                
                // Use Release as default if no configuration specified
                string buildConfig = string.IsNullOrWhiteSpace(configuration) ? "Release" : configuration;
                
                // Check if it's an SDK-style project (.NET Core/.NET 5+)
                // SDK-style projects use dotnet publish for deployment
                bool isSdkStyleProject = IsSdkStyleProject(projectFile);
                string targetFramework = GetTargetFramework(projectFile);
                
                if (isSdkStyleProject)
                {
                    // Use dotnet publish for SDK-style projects with explicit output path
                    string publishPath = Path.Combine(projectDir, "bin", buildConfig, "publish");
                    
                    WriteOutput($"Publishing to: {publishPath}");
                    
                    var startInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "dotnet",
                        Arguments = $"publish \"{projectFile}\" -c {buildConfig} -o \"{publishPath}\" --no-self-contained",
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        WorkingDirectory = projectDir
                    };

                    using (var process = System.Diagnostics.Process.Start(startInfo))
                    {
                        string output = process.StandardOutput.ReadToEnd();
                        string errors = process.StandardError.ReadToEnd();
                        process.WaitForExit();
                        
                        if (process.ExitCode != 0)
                        {
                            WriteOutput($"Publish failed with exit code {process.ExitCode}");
                            if (!string.IsNullOrWhiteSpace(errors))
                            {
                                WriteOutput(errors);
                            }
                            if (!string.IsNullOrWhiteSpace(output))
                            {
                                WriteOutput(output);
                            }
                            return null;
                        }
                    }
                    
                    WriteOutput("Publish finished.");
                    
                    // Verify publish folder exists
                    if (Directory.Exists(publishPath))
                    {
                        WriteOutput($"Publish successful: {publishPath}");
                        return publishPath;
                    }
                    
                    WriteOutput($"ERROR: Publish folder not found at {publishPath}");
                    return null;
                }
                else
                {
                    // Use DTE build for legacy projects
                    var solutionBuild = dte.Solution.SolutionBuild;
                    
                    // Find and activate the correct configuration
                    foreach (SolutionConfiguration2 config in solutionBuild.SolutionConfigurations)
                    {
                        if (config.Name.Equals(buildConfig, StringComparison.OrdinalIgnoreCase))
                        {
                            config.Activate();
                            break;
                        }
                    }
                    
                    solutionBuild.Build(true);
                    
                    if (solutionBuild.LastBuildInfo != 0)
                    {
                        WriteOutput($"Build failed with {solutionBuild.LastBuildInfo} error(s).");
                        return null;
                    }
                    
                    // Get output path for legacy project
                    string outputPath = project.ConfigurationManager?.ActiveConfiguration?.Properties?.Item("OutputPath")?.Value?.ToString();
                    
                    if (!string.IsNullOrEmpty(outputPath))
                    {
                        string fullOutputPath = Path.IsPathRooted(outputPath) 
                            ? outputPath 
                            : Path.Combine(projectDir, outputPath);
                        
                        return Path.GetFullPath(fullOutputPath);
                    }
                }
                
                return null;
            }
            catch (Exception ex)
            {
                WriteOutput($"Build error: {ex.Message}");
                WriteOutput($"Stack trace: {ex.StackTrace}");
                return null;
            }
        }

        private bool IsSdkStyleProject(string projectFile)
        {
            try
            {
                if (!File.Exists(projectFile)) return false;
                
                string content = File.ReadAllText(projectFile);
                // SDK-style projects have <Project Sdk="..."> at the root
                return content.Contains("<Project Sdk=\"") || content.Contains("Sdk=\"Microsoft.NET.Sdk");
            }
            catch
            {
                return false;
            }
        }

        private string GetTargetFramework(string projectFile)
        {
            try
            {
                if (!File.Exists(projectFile)) return null;
                
                string content = File.ReadAllText(projectFile);
                
                // Look for <TargetFramework>net6.0</TargetFramework> or similar
                var match = System.Text.RegularExpressions.Regex.Match(content, @"<TargetFramework>([^<]+)</TargetFramework>");
                if (match.Success)
                {
                    return match.Groups[1].Value;
                }
                
                // Look for <TargetFrameworks> (multiple)
                match = System.Text.RegularExpressions.Regex.Match(content, @"<TargetFrameworks>([^<]+)</TargetFrameworks>");
                if (match.Success)
                {
                    // Return first framework
                    return match.Groups[1].Value.Split(';')[0];
                }
                
                return null;
            }
            catch
            {
                return null;
            }
        }

        private void ActivateOutputWindow()
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            try
            {
                if (outputPane == null)
                {
                    var outWindow = Package.GetGlobalService(typeof(SVsOutputWindow)) as IVsOutputWindow;
                    var customGuid = new Guid("B2C3D4E5-6F78-90AB-CDEF-123456789ABC");
                    outWindow?.CreatePane(ref customGuid, "Deploy to IIS", 1, 1);
                    outWindow?.GetPane(ref customGuid, out outputPane);
                }

                // Clear previous output
                outputPane?.Clear();
                
                // Bring output window to front
                outputPane?.Activate();
                
                // Also activate the output tool window itself
                var outputWindow = Package.GetGlobalService(typeof(SVsOutputWindow)) as IVsOutputWindow;
                if (outputWindow != null)
                {
                    var vsUIShell = Package.GetGlobalService(typeof(SVsUIShell)) as IVsUIShell;
                    if (vsUIShell != null)
                    {
                        var outputToolWindowGuid = new Guid("{34E76E81-EE4A-11D0-AE2E-00A0C90FFFC3}");
                        IVsWindowFrame windowFrame;
                        vsUIShell.FindToolWindow(0, ref outputToolWindowGuid, out windowFrame);
                        windowFrame?.Show();
                    }
                }
            }
            catch
            {
                // Silently fail if output window is not available
            }
        }

        private void WriteOutput(string message)
        {
            try
            {
                ThreadHelper.JoinableTaskFactory.Run(async () =>
                {
                    await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();

                    if (outputPane == null)
                    {
                        var outWindow = Package.GetGlobalService(typeof(SVsOutputWindow)) as IVsOutputWindow;
                        var customGuid = new Guid("B2C3D4E5-6F78-90AB-CDEF-123456789ABC");
                        outWindow?.CreatePane(ref customGuid, "Deploy to IIS", 1, 1);
                        outWindow?.GetPane(ref customGuid, out outputPane);
                    }

                    // Activate the pane to keep it visible
                    outputPane?.Activate();
                    outputPane?.OutputStringThreadSafe(message + "\n");
                });
            }
            catch
            {
                // Silently fail if output window is not available
            }
        }

        private void ShowMessage(string title, string message)
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            VsShellUtilities.ShowMessageBox(
                this.package,
                message,
                title,
                OLEMSGICON.OLEMSGICON_INFO,
                OLEMSGBUTTON.OLEMSGBUTTON_OK,
                OLEMSGDEFBUTTON.OLEMSGDEFBUTTON_FIRST);
        }

        private static SecureString ConvertToSecureString(string password)
        {
            if (string.IsNullOrEmpty(password))
                return null;

            var securePassword = new SecureString();
            foreach (char c in password)
            {
                securePassword.AppendChar(c);
            }
            securePassword.MakeReadOnly();
            return securePassword;
        }
    }
}
