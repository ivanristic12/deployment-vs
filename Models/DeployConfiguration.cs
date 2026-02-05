using System;
using System.Linq;
using System.Text.Json.Serialization;

namespace IISDeployExtension.Models
{
    public class DeployConfiguration
    {
        public string Server { get; set; }
        public string PoolName { get; set; }
        public string AppFolderLocation { get; set; }
        public string BackupFolderLocation { get; set; }
        
        [JsonPropertyName("excludeFromCleanup")]
        public object ExcludeFromCleanupRaw { get; set; }
        
        [JsonPropertyName("excludeFromCopy")]
        public object ExcludeFromCopyRaw { get; set; }
        
        [JsonIgnore]
        public string[] ExcludeFromCleanup
        {
            get
            {
                if (ExcludeFromCleanupRaw == null) return new string[] { };
                if (ExcludeFromCleanupRaw is string strValue)
                {
                    if (string.IsNullOrWhiteSpace(strValue)) return new string[] { };
                    return strValue.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)
                        .Select(x => x.Trim()).Where(x => !string.IsNullOrEmpty(x)).ToArray();
                }
                if (ExcludeFromCleanupRaw is System.Text.Json.JsonElement jsonElement)
                {
                    if (jsonElement.ValueKind == System.Text.Json.JsonValueKind.Array)
                    {
                        return jsonElement.EnumerateArray()
                            .Select(x => x.GetString())
                            .Where(x => !string.IsNullOrWhiteSpace(x))
                            .ToArray();
                    }
                    if (jsonElement.ValueKind == System.Text.Json.JsonValueKind.String)
                    {
                        var strVal = jsonElement.GetString();
                        if (string.IsNullOrWhiteSpace(strVal)) return new string[] { };
                        return strVal.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)
                            .Select(x => x.Trim()).Where(x => !string.IsNullOrEmpty(x)).ToArray();
                    }
                }
                return new string[] { };
            }
        }
        
        [JsonIgnore]
        public string[] ExcludeFromCopy
        {
            get
            {
                if (ExcludeFromCopyRaw == null) return new string[] { };
                if (ExcludeFromCopyRaw is string strValue)
                {
                    if (string.IsNullOrWhiteSpace(strValue)) return new string[] { };
                    return strValue.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)
                        .Select(x => x.Trim()).Where(x => !string.IsNullOrEmpty(x)).ToArray();
                }
                if (ExcludeFromCopyRaw is System.Text.Json.JsonElement jsonElement)
                {
                    if (jsonElement.ValueKind == System.Text.Json.JsonValueKind.Array)
                    {
                        return jsonElement.EnumerateArray()
                            .Select(x => x.GetString())
                            .Where(x => !string.IsNullOrWhiteSpace(x))
                            .ToArray();
                    }
                    if (jsonElement.ValueKind == System.Text.Json.JsonValueKind.String)
                    {
                        var strVal = jsonElement.GetString();
                        if (string.IsNullOrWhiteSpace(strVal)) return new string[] { };
                        return strVal.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)
                            .Select(x => x.Trim()).Where(x => !string.IsNullOrEmpty(x)).ToArray();
                    }
                }
                return new string[] { };
            }
        }

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

