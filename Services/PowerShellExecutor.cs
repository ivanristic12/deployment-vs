using System;
using System.Diagnostics;
using System.Linq;
using System.Security;
using System.Text;
using System.Runtime.InteropServices;

namespace IISDeployExtension.Services
{
    public class PowerShellExecutor
    {
        public PowerShellResult ExecuteScript(string scriptPath, string server = null, string username = null, SecureString password = null, string testPath = null)
        {
            var result = new PowerShellResult();

            try
            {
                // Build arguments
                var args = new StringBuilder($"-ExecutionPolicy Bypass -File \"{scriptPath}\"");

                if (!string.IsNullOrEmpty(server))
                    args.Append($" -Server \"{server}\"");

                if (!string.IsNullOrEmpty(username))
                    args.Append($" -Username \"{username}\"");

                if (password != null)
                {
                    // Convert SecureString to Base64 for safe passing
                    string passwordBase64 = SecureStringToBase64(password);
                    args.Append($" -PasswordBase64 \"{passwordBase64}\"");
                }

                if (!string.IsNullOrEmpty(testPath))
                    args.Append($" -TestPath \"{testPath}\"");

                var startInfo = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = args.ToString(),
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (var process = Process.Start(startInfo))
                {
                    var output = process.StandardOutput.ReadToEnd();
                    var errors = process.StandardError.ReadToEnd();

                    process.WaitForExit();

                    result.Output.Append(output);

                    if (!string.IsNullOrWhiteSpace(errors))
                    {
                        result.Errors.Append(errors);
                        result.Success = false;
                    }
                    else if (process.ExitCode == 0)
                    {
                        result.Success = true;
                    }
                    else
                    {
                        result.Success = false;
                        result.Errors.AppendLine($"Exit code: {process.ExitCode}");
                    }
                }
            }
            catch (Exception ex)
            {
                result.Success = false;
                result.Errors.AppendLine($"Exception: {ex.Message}");
            }

            return result;
        }

        public PowerShellResult TestCredentials(string scriptPath, string server, string username, SecureString password, string testPath)
        {
            return ExecuteScript(scriptPath, server, username, password, testPath);
        }

        public PowerShellResult ExecuteDeploy(
            string scriptPath, 
            string server, 
            string username, 
            SecureString password,
            string appPoolName,
            string appFolderLocation,
            string newFilesPath,
            string backupFolder,
            string[] excludeFromCleanup,
            string[] excludeFromCopy,
            Action<string> outputCallback = null)
        {
            var result = new PowerShellResult();

            try
            {
                // Build arguments
                var args = new StringBuilder($"-ExecutionPolicy Bypass -File \"{scriptPath}\"");

                args.Append($" -Server \"{server}\"");
                args.Append($" -Username \"{username}\"");

                if (password != null)
                {
                    string passwordBase64 = SecureStringToBase64(password);
                    args.Append($" -PasswordBase64 \"{passwordBase64}\"");
                }

                args.Append($" -AppPoolName \"{appPoolName}\"");
                args.Append($" -AppFolderLocation \"{appFolderLocation}\"");
                args.Append($" -NewFilesPath \"{newFilesPath}\"");
                args.Append($" -BackupFolder \"{backupFolder}\"");

                // Handle exclude arrays - pass as comma-separated values
                if (excludeFromCleanup != null && excludeFromCleanup.Length > 0)
                {
                    var items = excludeFromCleanup.Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim());
                    args.Append($" -ExcludeFromCleanup \"{string.Join(",", items)}\"");
                }

                if (excludeFromCopy != null && excludeFromCopy.Length > 0)
                {
                    var items = excludeFromCopy.Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim());
                    args.Append($" -ExcludeFromCopy \"{string.Join(",", items)}\"");
                }

                var startInfo = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = args.ToString(),
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (var process = Process.Start(startInfo))
                {
                    // Stream output in real-time
                    while (!process.StandardOutput.EndOfStream)
                    {
                        string line = process.StandardOutput.ReadLine();
                        if (line != null)
                        {
                            result.Output.AppendLine(line);
                            outputCallback?.Invoke(line);
                        }
                    }

                    process.WaitForExit();

                    // Read any remaining errors
                    string errors = process.StandardError.ReadToEnd();

                    if (!string.IsNullOrWhiteSpace(errors))
                    {
                        result.Errors.Append(errors);
                        result.Success = false;
                        outputCallback?.Invoke($"ERROR: {errors}");
                    }
                    else if (process.ExitCode == 0)
                    {
                        result.Success = true;
                    }
                    else
                    {
                        result.Success = false;
                        result.Errors.AppendLine($"Exit code: {process.ExitCode}");
                    }
                }
            }
            catch (Exception ex)
            {
                result.Success = false;
                result.Errors.AppendLine($"Exception: {ex.Message}");
                outputCallback?.Invoke($"EXCEPTION: {ex.Message}");
            }

            return result;
        }

        private string SecureStringToBase64(SecureString value)
        {
            IntPtr valuePtr = IntPtr.Zero;
            try
            {
                valuePtr = Marshal.SecureStringToGlobalAllocUnicode(value);
                string plainText = Marshal.PtrToStringUni(valuePtr);
                byte[] bytes = System.Text.Encoding.Unicode.GetBytes(plainText);
                return Convert.ToBase64String(bytes);
            }
            finally
            {
                Marshal.ZeroFreeGlobalAllocUnicode(valuePtr);
            }
        }
    }

    public class PowerShellResult
    {
        public bool Success { get; set; }
        public StringBuilder Output { get; set; } = new StringBuilder();
        public StringBuilder Errors { get; set; } = new StringBuilder();

        public string GetOutput() => Output.ToString();
        public string GetErrors() => Errors.ToString();
    }
}


