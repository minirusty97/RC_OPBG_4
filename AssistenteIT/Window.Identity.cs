using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace AssistenteIT {
    public static class WindowIdentity {
        public const string AppId = "AssistenteIT.Desktop";
        [DllImport("shell32.dll", CharSet=CharSet.Unicode)] private static extern int SetCurrentProcessExplicitAppUserModelID(string id);
        [DllImport("shell32.dll")] private static extern int GetCurrentProcessExplicitAppUserModelID(out IntPtr id);
        [DllImport("shell32.dll")] private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, out IPropertyStore store);
        [ComImport, Guid("00021401-0000-0000-C000-000000000046")] private class ShellLink { }
        [StructLayout(LayoutKind.Sequential)] private struct PropertyKey {
            public Guid Format; public uint Id;
            public PropertyKey(uint id) { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); Id=id; }
        }
        [StructLayout(LayoutKind.Explicit, Size=24)] private struct PropVariant : IDisposable {
            [FieldOffset(0)] public ushort Type;
            [FieldOffset(8)] public IntPtr Pointer;
            public static PropVariant Text(string value) { return new PropVariant { Type=31, Pointer=Marshal.StringToCoTaskMemUni(value) }; }
            public string StringValue { get { return Type==31 ? Marshal.PtrToStringUni(Pointer) : null; } }
            public void Dispose() { if(Type==31 && Pointer!=IntPtr.Zero) Marshal.FreeCoTaskMem(Pointer); Pointer=IntPtr.Zero;Type=0; }
        }
        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [PreserveSig] int Commit();
        }
        private static void Set(IPropertyStore store, uint id, string text) {
            var key=new PropertyKey(id);var value=PropVariant.Text(text);
            try { Marshal.ThrowExceptionForHR(store.SetValue(ref key,ref value)); }
            finally { value.Dispose(); }
        }
        public static void Initialize() { Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(AppId)); }
        public static string CurrentId() {
            IntPtr p;Marshal.ThrowExceptionForHR(GetCurrentProcessExplicitAppUserModelID(out p));
            try { return Marshal.PtrToStringUni(p); } finally { Marshal.FreeCoTaskMem(p); }
        }
        public static void Apply(IntPtr window) { Apply(window,null); }
        public static void Apply(IntPtr window, string launcher) {
            var iid=typeof(IPropertyStore).GUID;IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window,ref iid,out store));
            try {
                if (!String.IsNullOrEmpty(launcher) && File.Exists(launcher)) {
                    Set(store,2,"\""+launcher+"\"");Set(store,3,launcher+",0");Set(store,4,"Assistente IT");
                }
                Set(store,5,AppId);
            }
            finally { Marshal.ReleaseComObject(store); }
        }
        public static string WindowId(IntPtr window) {
            var iid=typeof(IPropertyStore).GUID;IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window,ref iid,out store));
            try { var key=new PropertyKey(5);PropVariant value;Marshal.ThrowExceptionForHR(store.GetValue(ref key,out value));try { return value.StringValue; } finally { value.Dispose(); } }
            finally { Marshal.ReleaseComObject(store); }
        }
        public static void SetShortcut(string path) {
            if (!File.Exists(path)) return;
            object link=new ShellLink();
            try { var file=(IPersistFile)link;file.Load(path,0);var store=(IPropertyStore)link;Set(store,5,AppId);Marshal.ThrowExceptionForHR(store.Commit());file.Save(path,true); }
            finally { Marshal.ReleaseComObject(link); }
        }
    }
}
