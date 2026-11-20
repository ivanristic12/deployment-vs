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
        /// <summary>
        /// Full path to Windows PowerShell. SECURITY: never start "powershell.exe" by bare name -
        /// Windows would search Visual Studio's current directory (often the solution folder) first,
        /// so a planted powershell.exe in a repository would be executed and receive the password.
        /// </summary>
        internal static string PowerShellPath =>
            System.IO.Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

        /// <summary>
        /// Resolves dotnet.exe from absolute PATH entries only (relative entries and the current
        /// directory are skipped), falling back to the default install location.
        /// </summary>
        internal static string ResolveDotnetPath()
        {
            var pathVar = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            foreach (var dir in pathVar.Split(System.IO.Path.PathSeparator))
            {
                try
                {
                    var d = dir.Trim().Trim('"');
                    if (d.Length == 0 || !System.IO.Path.IsPathRooted(d)) continue;
                    var candidate = System.IO.Path.Combine(d, "dotnet.exe");
                    if (System.IO.File.Exists(candidate)) return candidate;
                }
                catch { /* invalid PATH entry */ }
            }

            var fallback = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "dotnet", "dotnet.exe");
            if (System.IO.File.Exists(fallback)) return fallback;

            throw new System.IO.FileNotFoundException("dotnet.exe was not found. Please install the .NET SDK.");
        }

        /// <summary>
        /// Quotes a single command-line argument per the Windows (CommandLineToArgvW) rules, so that
        /// quotes inside a value cannot inject extra parameters and a trailing backslash
        /// (e.g. "C:\inetpub\app\") cannot escape the closing quote.
        /// </summary>
        internal static string Q(string value)
        {
            if (value == null) value = string.Empty;
            var sb = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { backslashes++; continue; }
                if (c == '"')
                {
                    sb.Append('\\', backslashes * 2 + 1).Append('"');
                }
                else
                {
                    sb.Append('\\', backslashes).Append(c);
                }
                backslashes = 0;
            }
            sb.Append('\\', backslashes * 2).Append('"');
            return sb.ToString();
        }

        public PowerShellResult ExecuteScript(string scriptPath, string server = null, string username = null, SecureString password = null, string testPath = null)
        {
            var result = new PowerShellResult();

            try
            {
                // Build arguments
                // -NoProfile: don't load the user's PowerShell profile (faster startup)
                var args = new StringBuilder($"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {Q(scriptPath)}");

                if (!string.IsNullOrEmpty(server))
                    args.Append($" -Server {Q(server)}");

                if (!string.IsNullOrEmpty(username))
                    args.Append($" -Username {Q(username)}");

                // NOTE: the password is NEVER put on the command line (it would be visible to other
                // processes and can end up in logs, transcripts, EDR/audit data). It is sent via stdin.

                if (!string.IsNullOrEmpty(testPath))
                    args.Append($" -TestPath {Q(testPath)}");

                var startInfo = new ProcessStartInfo
                {
                    FileName = PowerShellPath,
                    Arguments = args.ToString(),
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (var process = Process.Start(startInfo))
                {
                    WritePasswordToStdin(process, password);

                    // Read both streams concurrently to avoid a deadlock when one buffer fills up
                    var errorsTask = process.StandardError.ReadToEndAsync();
                    var output = process.StandardOutput.ReadToEnd();
                    var errors = errorsTask.GetAwaiter().GetResult();

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
                // -NoProfile: don't load the user's PowerShell profile (faster startup)
                var args = new StringBuilder($"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {Q(scriptPath)}");

                args.Append($" -Server {Q(server)}");
                args.Append($" -Username {Q(username)}");

                // Password is sent via stdin, never on the command line (see ExecuteScript)

                args.Append($" -AppPoolName {Q(appPoolName)}");
                args.Append($" -AppFolderLocation {Q(appFolderLocation)}");
                args.Append($" -NewFilesPath {Q(newFilesPath)}");
                args.Append($" -BackupFolder {Q(backupFolder)}");

                // Handle exclude arrays - pass as comma-separated values
                if (excludeFromCleanup != null && excludeFromCleanup.Length > 0)
                {
                    var items = excludeFromCleanup.Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim());
                    args.Append($" -ExcludeFromCleanup {Q(string.Join(",", items))}");
                }

                if (excludeFromCopy != null && excludeFromCopy.Length > 0)
                {
                    var items = excludeFromCopy.Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim());
                    args.Append($" -ExcludeFromCopy {Q(string.Join(",", items))}");
                }

                var startInfo = new ProcessStartInfo
                {
                    FileName = PowerShellPath,
                    Arguments = args.ToString(),
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (var process = Process.Start(startInfo))
                {
                    WritePasswordToStdin(process, password);

                    // Read stderr concurrently, otherwise a full stderr buffer can deadlock the script
                    var errorsTask = process.StandardError.ReadToEndAsync();

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
                    string errors = errorsTask.GetAwaiter().GetResult();

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

        /// <summary>
        /// Sends the password to the script through stdin (a single base64 line, UTF-16LE bytes),
        /// then closes stdin. Nothing is written to disk or to the process command line.
        /// The script reads it with [Console]::In.ReadLine().
        /// </summary>
        private static void WritePasswordToStdin(Process process, SecureString password)
        {
            byte[] bytes = null;
            try
            {
                string line = password != null ? SecureStringToBase64(password) : string.Empty;
                // Write raw ASCII bytes (base64 is pure ASCII) to avoid any console encoding issues
                bytes = Encoding.ASCII.GetBytes(line + "\r\n");
                process.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
                process.StandardInput.BaseStream.Flush();
            }
            finally
            {
                if (bytes != null) Array.Clear(bytes, 0, bytes.Length);
                try { process.StandardInput.Close(); } catch { /* process may have exited */ }
            }
        }

        private static string SecureStringToBase64(SecureString value)
        {
            IntPtr valuePtr = IntPtr.Zero;
            byte[] bytes = null;
            try
            {
                valuePtr = Marshal.SecureStringToGlobalAllocUnicode(value);
                bytes = new byte[value.Length * 2];
                Marshal.Copy(valuePtr, bytes, 0, bytes.Length);
                return Convert.ToBase64String(bytes);
            }
            finally
            {
                if (bytes != null) Array.Clear(bytes, 0, bytes.Length);
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


