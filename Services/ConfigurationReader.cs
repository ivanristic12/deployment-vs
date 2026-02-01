using System;
using System.IO;
using System.Text.Json;
using IISDeployExtension.Models;

namespace IISDeployExtension.Services
{
    public class ConfigurationReader
    {
        public static DeployConfiguration ReadConfiguration(string configPath)
        {
            if (!File.Exists(configPath))
            {
                throw new FileNotFoundException($"Configuration file not found: {configPath}");
            }

            try
            {
                string json = File.ReadAllText(configPath);
                var config = JsonSerializer.Deserialize<DeployConfiguration>(json, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });

                if (config == null)
                {
                    throw new InvalidOperationException("Failed to deserialize configuration file.");
                }

                config.Validate();
                return config;
            }
            catch (JsonException ex)
            {
                throw new InvalidOperationException($"Invalid JSON in configuration file: {ex.Message}", ex);
            }
        }
    }
}
