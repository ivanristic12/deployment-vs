using System;
using System.IO;
using EnvDTE;
using Microsoft.VisualStudio.Shell;

namespace IISDeployExtension.Helpers
{
    public static class ProjectHelper
    {
        public static string GetProjectDirectory(Project project)
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            if (project == null)
                throw new ArgumentNullException(nameof(project));

            try
            {
                // Try getting FullPath property
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
                catch (Exception ex)
                {
                    throw new InvalidOperationException($"Could not determine project directory for {project.Name}", ex);
                }
            }
        }

        public static string GetProjectFile(Project project)
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            if (project == null)
                throw new ArgumentNullException(nameof(project));

            return project.FileName;
        }

        public static string GetProjectName(Project project)
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            if (project == null)
                throw new ArgumentNullException(nameof(project));

            return project.Name;
        }

        public static bool IsNetCoreProject(Project project)
        {
            ThreadHelper.ThrowIfNotOnUIThread();

            try
            {
                string projectFile = GetProjectFile(project);
                if (string.IsNullOrEmpty(projectFile) || !File.Exists(projectFile))
                    return false;

                string content = File.ReadAllText(projectFile);
                
                // Check if it's SDK-style project
                return content.Contains("Sdk=\"Microsoft.NET.Sdk.Web\"") ||
                       content.Contains("Sdk=\"Microsoft.NET.Sdk\"");
            }
            catch
            {
                return false;
            }
        }
    }
}
