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
    // uses CREATE_NO_WINDOW. Keep a hidden console handle, owned by the visible
    // application window, so the SDK resolves the GUI as the WAM parent.
    public sealed class GraphAuthConsole : IDisposable
    {
        [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AllocConsole();
        [DllImport("kernel32.dll")] private static extern uint GetConsoleCP();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool FreeConsole();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool SetConsoleTitle(string title);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr handle);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr handle, int command);
        [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr handle);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
        [DllImport("kernel32.dll")] private static extern void SetLastError(uint error);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", ExactSpelling = true)] private static extern IntPtr GetOwner64(IntPtr handle, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW", ExactSpelling = true)] private static extern int GetOwner32(IntPtr handle, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", ExactSpelling = true, SetLastError = true)] private static extern IntPtr SetOwner64(IntPtr handle, int index, IntPtr owner);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW", ExactSpelling = true, SetLastError = true)] private static extern int SetOwner32(IntPtr handle, int index, int owner);
        private static IntPtr applicationWindow;
        private static IntPtr ownedConsole;
        private static IntPtr previousOwner;
        private IntPtr handle;
        private bool wasVisible;

        private static IntPtr ReadOwner(IntPtr window) { return IntPtr.Size == 8 ? GetOwner64(window, -8) : new IntPtr(GetOwner32(window, -8)); }
        private static void WriteOwner(IntPtr window, IntPtr owner)
        {
            SetLastError(0);
            IntPtr result = IntPtr.Size == 8 ? SetOwner64(window, -8, owner) : new IntPtr(SetOwner32(window, -8, owner.ToInt32()));
            int error = Marshal.GetLastWin32Error();
            if (result == IntPtr.Zero && error != 0) throw new InvalidOperationException("Impossibile associare l'accesso Microsoft alla finestra dell'app (Windows " + error + ").");
        }
        public static void RegisterOwner(IntPtr window)
        {
            uint processId;
            if (!IsWindow(window) || GetWindowThreadProcessId(window, out processId) == 0 || processId != System.Diagnostics.Process.GetCurrentProcess().Id)
                throw new ArgumentException("Finestra dell'app non valida.");
            applicationWindow = window;
        }
        public static void ReleaseOwner()
        {
            if (ownedConsole != IntPtr.Zero && IsWindow(ownedConsole) && ReadOwner(ownedConsole) == applicationWindow)
                WriteOwner(ownedConsole, previousOwner);
            ownedConsole = IntPtr.Zero; previousOwner = IntPtr.Zero; applicationWindow = IntPtr.Zero;
        }
        private GraphAuthConsole() { }
        public static GraphAuthConsole Open()
        {
            var scope = new GraphAuthConsole();
            if (Environment.OSVersion.Platform != PlatformID.Win32NT) return scope;
            scope.handle = GetConsoleWindow();
            scope.wasVisible = scope.handle != IntPtr.Zero && IsWindowVisible(scope.handle);
            if (scope.handle == IntPtr.Zero)
            {
                // CREATE_NO_WINDOW attaches a windowless console. Detach it
                // before allocating a visible owner; otherwise AllocConsole fails.
                if (GetConsoleCP() != 0 && !FreeConsole()) throw new InvalidOperationException("Impossibile preparare la finestra Microsoft (Windows " + Marshal.GetLastWin32Error() + ").");
                if (!AllocConsole()) throw new InvalidOperationException("Impossibile creare la finestra per l'accesso Microsoft (Windows " + Marshal.GetLastWin32Error() + "). Chiudere e riaprire Assistente IT.");
                scope.handle = GetConsoleWindow();
                SetConsoleTitle("Accesso Microsoft - Assistente IT");
            }
            if (scope.handle == IntPtr.Zero) throw new InvalidOperationException("Finestra di accesso Microsoft non disponibile.");
            if (!scope.wasVisible)
            {
                ShowWindow(scope.handle, 0);
                if (applicationWindow != IntPtr.Zero && IsWindow(applicationWindow))
                {
                    if (ownedConsole != scope.handle) { ownedConsole = scope.handle; previousOwner = ReadOwner(scope.handle); }
                    WriteOwner(scope.handle, applicationWindow);
                }
            }
            return scope;
        }
        public void Dispose()
        {
            if (handle != IntPtr.Zero && !wasVisible) ShowWindow(handle, 0);
            handle = IntPtr.Zero;
        }
    }

}
