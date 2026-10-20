using System;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;

namespace AssistenteIT
{
    public sealed class GraphLoginNotice
    {
        public string Kind { get; set; }
        public string Message { get; set; }
        public string Code { get; set; }
        public string Uri { get; set; }
    }

    // Graph's device callback may fall back to Console.WriteLine on a .NET thread.
    // Do not call PowerShell or WinForms from that thread: enqueue a plain notice.
    public sealed class GraphLoginBridge : TextWriter
    {
        private readonly ConcurrentQueue<object> queue;
        private readonly TextWriter original;
        private TextWriter installed;
        private readonly object gate = new object();
        private readonly StringBuilder pending = new StringBuilder();
        private string lastCode;
        private bool disposed;
        public override Encoding Encoding { get { return original.Encoding; } }

        private GraphLoginBridge(ConcurrentQueue<object> target)
        {
            queue = target;
            original = Console.Out;
            Console.SetOut(this);
            installed = Console.Out;
        }
        public static GraphLoginBridge Capture(ConcurrentQueue<object> target)
        {
            if (target == null) throw new ArgumentNullException("target");
            return new GraphLoginBridge(target);
        }
        public bool TryPublish(string message)
        {
            if (String.IsNullOrWhiteSpace(message) ||
                !Regex.IsMatch(message, @"https://(?:www\.)?microsoft\.com/devicelogin(?:\b|/)", RegexOptions.IgnoreCase)) return false;
            Match match = Regex.Match(message, @"(?:code|codice)\s+([A-Z0-9-]{6,20})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (!match.Success) match = Regex.Match(message, @"\b([A-Z0-9]{9})\b", RegexOptions.CultureInvariant);
            if (!match.Success) return false;
            string code = match.Groups[1].Value.ToUpperInvariant();
            lock (gate)
            {
                if (disposed) return false;
                if (code == lastCode) return true;
                lastCode = code;
                queue.Enqueue(new GraphLoginNotice { Kind = "GraphLogin", Message = message.Trim(), Code = code, Uri = "https://microsoft.com/devicelogin" });
                return true;
            }
        }
        private void Observe(string text)
        {
            lock (gate)
            {
                if (disposed) return;
                pending.Append(text);
                if (TryPublish(pending.ToString())) pending.Clear();
                else if (pending.Length > 8192) pending.Remove(0, pending.Length - 4096);
            }
        }
        public override void Write(string value) { original.Write(value); Observe(value); }
        public override void Write(char value) { original.Write(value); Observe(value.ToString()); }
        public override void WriteLine(string value) { original.WriteLine(value); Observe(value + Environment.NewLine); }
        public override void Flush() { original.Flush(); }
        protected override void Dispose(bool disposing)
        {
            lock (gate)
            {
                if (disposed) return;
                disposed = true;
                if (Object.ReferenceEquals(Console.Out, installed)) Console.SetOut(original);
                pending.Clear();
            }
            base.Dispose(disposing);
        }
    }
    // The Graph SDK obtains WAM's parent from GetConsoleWindow. A GUI launcher
    // uses CREATE_NO_WINDOW, so create a real console owner during sign-in.
    // Keep its handle alive for later silent refreshes; hide it when sign-in ends.
    public sealed class GraphAuthConsole : IDisposable
    {
        [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AllocConsole();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool SetConsoleTitle(string title);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr handle);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr handle, int command);
        private IntPtr handle;
        private bool wasVisible;
        private GraphAuthConsole() { }
        public static GraphAuthConsole Open()
        {
            var scope = new GraphAuthConsole();
            if (Environment.OSVersion.Platform != PlatformID.Win32NT) return scope;
            scope.handle = GetConsoleWindow();
            scope.wasVisible = scope.handle != IntPtr.Zero && IsWindowVisible(scope.handle);
            if (scope.handle == IntPtr.Zero)
            {
                if (!AllocConsole()) throw new InvalidOperationException("Impossibile creare la finestra per l'accesso Microsoft (Windows " + Marshal.GetLastWin32Error() + "). Chiudere e riaprire Assistente IT.");
                scope.handle = GetConsoleWindow();
                SetConsoleTitle("Accesso Microsoft - Assistente IT");
            }
            if (scope.handle == IntPtr.Zero) throw new InvalidOperationException("Finestra di accesso Microsoft non disponibile.");
            ShowWindow(scope.handle, 5);
            return scope;
        }
        public void Dispose()
        {
            if (handle != IntPtr.Zero && !wasVisible) ShowWindow(handle, 0);
            handle = IntPtr.Zero;
        }
    }

}
