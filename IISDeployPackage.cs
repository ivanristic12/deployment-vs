using System;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.VisualStudio.Shell;
using Task = System.Threading.Tasks.Task;

namespace IISDeployExtension
{
    [PackageRegistration(UseManagedResourcesOnly = true, AllowsBackgroundLoading = true)]
    [Guid(IISDeployPackage.PackageGuidString)]
    [ProvideMenuResource("Menus.ctmenu", 1)]
    [ProvideAutoLoad(Microsoft.VisualStudio.Shell.Interop.UIContextGuids.SolutionExists, PackageAutoLoadFlags.BackgroundLoad)]
    public sealed class IISDeployPackage : AsyncPackage
    {
        public const string PackageGuidString = "a1b2c3d4-5e6f-7890-abcd-ef1234567890";

        #region Package Members

        protected override async Task InitializeAsync(CancellationToken cancellationToken, IProgress<ServiceProgressData> progress)
        {
            await this.JoinableTaskFactory.SwitchToMainThreadAsync(cancellationToken);
            
            // Initialize the command
            await DeployToIISCommand.InitializeAsync(this);
        }

        #endregion
    }
}
