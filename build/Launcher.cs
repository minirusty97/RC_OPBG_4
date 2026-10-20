using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Assistente IT")]
[assembly: AssemblyProduct("Assistente IT")]
[assembly: AssemblyVersion("__VERSION__.0")]
[assembly: AssemblyFileVersion("__VERSION__.0")]

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string app = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app");
            string script = Path.Combine(app, "Start-AssistenteIT.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Installazione incompleta. Reinstallare Assistente IT.");
            string powerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            string arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
            if (args.Length == 2 && args[0] == "--smoke-test")
            {
                if (args[1].IndexOf('"') >= 0) throw new ArgumentException("Percorso di verifica non valido.");
                arguments += " -SmokeTestOutput \"" + Path.GetFullPath(args[1]) + "\"";
            }
            else if (args.Length != 0) throw new ArgumentException("Avviare Assistente IT dal collegamento nel menu Start.");
            var start = new ProcessStartInfo(powerShell, arguments);
            start.WorkingDirectory = app;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            using (var process = Process.Start(start))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            if (args.Length > 0 && args[0] == "--smoke-test") return 1;
            MessageBox.Show(error.Message, "Assistente IT", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
