using System;

namespace IISDeployExtension.Models
{
    public class DeployConfiguration
    {
        public string Server { get; set; }
        public string PoolName { get; set; }
        public string AppFolderLocation { get; set; }
        public string BackupFolderLocation { get; set; }
        public string ExcludeFromCleanup { get; set; }
        public string ExcludeFromCopy { get; set; }
        public string DefaultConfiguration { get; set; }

        public void Validate()
        {
            if (string.IsNullOrWhiteSpace(Server))
                throw new InvalidOperationException("server is required in deploy.config.json");

            if (string.IsNullOrWhiteSpace(PoolName))
                throw new InvalidOperationException("poolName is required in deploy.config.json");

            if (string.IsNullOrWhiteSpace(AppFolderLocation))
                throw new InvalidOperationException("appFolderLocation is required in deploy.config.json");

            if (string.IsNullOrWhiteSpace(BackupFolderLocation))
                throw new InvalidOperationException("backupFolderLocation is required in deploy.config.json");
        }

        public override string ToString()
        {
            return $"Server: {Server}, Pool: {PoolName}, AppFolder: {AppFolderLocation}";
        }
    }
}

