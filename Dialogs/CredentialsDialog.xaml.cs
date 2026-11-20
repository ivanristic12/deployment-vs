using System;
using System.Windows;
using System.Windows.Media;

namespace IISDeployExtension.Dialogs
{
    public partial class CredentialsDialog : Window
    {
        public string Username { get; private set; }
        public string Password { get; private set; }
        public string Configuration { get; private set; }
        
        private Func<string, string, string, System.Threading.Tasks.Task<bool>> validationCallback;

        public CredentialsDialog(string defaultConfiguration = "", Func<string, string, string, System.Threading.Tasks.Task<bool>> validateCredentials = null)
        {
            InitializeComponent();
            
            validationCallback = validateCredentials;
            
            // Do not pre-fill configuration field - leave empty

            // Focus on username field
            Loaded += (s, e) => UsernameTextBox.Focus();

            // Don't allow closing the window (X / Esc) while validation is running
            Closing += (s, e) => { if (isValidating) e.Cancel = true; };
        }

        private bool isValidating;

#pragma warning disable VSTHRD100 // async void is required for WPF event handlers; all exceptions are caught below
        private async void OkButton_Click(object sender, RoutedEventArgs e)
#pragma warning restore VSTHRD100
        {
            // Validate inputs
            if (string.IsNullOrWhiteSpace(UsernameTextBox.Text))
            {
                MessageBox.Show("Please enter a username.", "Validation Error", MessageBoxButton.OK, MessageBoxImage.Warning);
                UsernameTextBox.Focus();
                return;
            }

            if (string.IsNullOrWhiteSpace(PasswordBox.Password))
            {
                MessageBox.Show("Please enter a password.", "Validation Error", MessageBoxButton.OK, MessageBoxImage.Warning);
                PasswordBox.Focus();
                return;
            }

            // Store values
            Username = UsernameTextBox.Text.Trim();
            Password = PasswordBox.Password;
            Configuration = ConfigurationTextBox.Text.Trim();

            // If validation callback is provided, validate before closing
            if (validationCallback != null)
            {
                // Show validating status
                SetStatus("Validating credentials...", Brushes.Blue);
                DisableInputs(true);
                CancelButton.IsEnabled = false;
                isValidating = true;

                try
                {
                    // Validate (the callback runs the slow PowerShell work off the UI thread)
                    bool isValid;
                    try
                    {
                        isValid = await validationCallback(Username, Password, Configuration);
                    }
                    finally
                    {
                        isValidating = false;
                    }

                    if (isValid)
                    {
                        SetStatus("Credentials valid!", Brushes.Green);
                        // Close dialog with OK result
                        DialogResult = true;
                        Close();
                    }
                    else
                    {
                        SetStatus("", Brushes.Black);
                        DisableInputs(false);
                        // Keep dialog open for retry
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Validation error: {ex.Message}", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
                    SetStatus("", Brushes.Black);
                    DisableInputs(false);
                }
                finally
                {
                    CancelButton.IsEnabled = true;
                }
            }
            else
            {
                // No validation callback, just close
                DialogResult = true;
                Close();
            }
        }

        private void SetStatus(string message, Brush color)
        {
            StatusTextBlock.Text = message;
            StatusTextBlock.Foreground = color;
        }

        private void DisableInputs(bool disable)
        {
            UsernameTextBox.IsEnabled = !disable;
            PasswordBox.IsEnabled = !disable;
            ConfigurationTextBox.IsEnabled = !disable;
            OkButton.IsEnabled = !disable;
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            // Close dialog with Cancel result
            DialogResult = false;
            Close();
        }
    }
}
