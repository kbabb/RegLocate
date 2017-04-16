#Requires -RunAsAdministrator

$code=@"

using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

namespace Registry
{
    
    public class KeyLocator : IDisposable
    {
        
        public KeyLocator()
        {
            
            uint processId;
            //start regedit if not
            Process[] processes = Process.GetProcessesByName("RegEdit");
            if (processes.Length == 0)
            {
                using (Process process = new Process())
                {
                    process.StartInfo.FileName = "RegEdit.exe";
                    process.Start();

                    process.WaitForInputIdle();

                    wndApp = process.MainWindowHandle;
                    processId = (uint)process.Id;

                }
            }
            else
            {
                wndApp = processes[0].MainWindowHandle;
                processId = (uint)processes[0].Id;

                const int SW_RESTORE = 9;
                Interop.ShowWindow(wndApp, SW_RESTORE);
            }

            if (wndApp == IntPtr.Zero)
            {
                throw new SystemException("no app handle");
            }

            // get handle to treeview
            wndTreeView = Interop.FindWindowEx(wndApp, IntPtr.Zero, "SysTreeView32", null);
            if (wndTreeView == IntPtr.Zero)
            {
                throw new SystemException("no treeview");
            }

            // get handle to listview
            wndListView = Interop.FindWindowEx(wndApp, IntPtr.Zero, "SysListView32", null);
            if (wndListView == IntPtr.Zero)
            {
                throw new SystemException("no listview");
            }


            // allocate buffer in local process
            lpLocalBuffer = Marshal.AllocHGlobal(dwBufferSize);
            if (lpLocalBuffer == IntPtr.Zero)
                throw new SystemException("Failed to allocate memory in local process");

            hProcess = Interop.OpenProcess(Interop.PROCESS_ALL_ACCESS, false, processId);
            if (hProcess == IntPtr.Zero)
                throw new ApplicationException("Failed to access process");

            // Allocate a buffer in the remote process
            lpRemoteBuffer = Interop.VirtualAllocEx(hProcess, IntPtr.Zero, dwBufferSize, Interop.MEM_COMMIT, Interop.PAGE_READWRITE);
            if (lpRemoteBuffer == IntPtr.Zero)
                throw new SystemException("Failed to allocate memory in remote process");
        }

        ~KeyLocator()
        {
            Dispose(false);
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            Dispose(true);

        }

        public void Close()
        {
            Dispose();
        }

        #region public 


        /// <summary>
        /// Opens RegEdit.exe and navigates to given registry path and value 
        /// </summary>
        /// <param name="keyPath">path of registry key</param>
        /// <param name="valueName">name of registry value</param>
        public static void Locate(string keyPath, string valueName)
        {
            using (KeyLocator locator = new KeyLocator())
            {
                bool hasValue = !(valueName == null || valueName.Length <= 0);
                locator.OpenKey(keyPath, !hasValue);

                if (hasValue)
                {
                    System.Threading.Thread.Sleep(200);
                    locator.OpenValue(valueName);
                }

                Process[] processes = Process.GetProcessesByName("RegEdit");
                wndApp1 = processes[0].MainWindowHandle;
                IntPtr HWND_TOPMOST = new IntPtr(-1);
                IntPtr HWND_TOP = new IntPtr(-2);
                const UInt32 SWP_NOSIZE = 0x0001;
                const UInt32 SWP_NOMOVE = 0x0002;
                const UInt32 SWP_SHOWWINDOW = 0x0040;
                //if found bring regedit to the top most
                if (found)
                {
                    Interop.SetWindowPos(wndApp1, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
                    Interop.SetWindowPos(wndApp1, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
                }

            }


        }

        /// <summary>
        /// Opens RegEdit.exe and navigates to given registry path 
        /// </summary>
        /// <param name="keyPath">path of registry key</param>
        public static void Locate(string keyPath)
        {
            Locate(keyPath, null);
        }

        #endregion


        #region private

        private void OpenKey(string path, bool select)
        {
            if (path == null || path.Length <= 0) return;

            const int TVGN_CARET = 0x0009;

            if (path.StartsWith("HKLM"))
            {
                path = "HKEY_LOCAL_MACHINE" + path.Remove(0, 4);
            }
            else if (path.StartsWith("HKCU"))
            {
                path = "HKEY_CURRENT_USER" + path.Remove(0, 4);
            }
            else if (path.StartsWith("HKCR"))
            {
                path = "HKEY_CLASSES_ROOT" + path.Remove(0, 4);
            }

            Interop.SendMessage(wndTreeView, Interop.WM.SETFOCUS, 0, 0);

            IntPtr tvItem = Interop.SendMessage(wndTreeView, Interop.TVM.GETNEXTITEM, Interop.TVGN.ROOT, IntPtr.Zero);
            foreach (string key in path.Split('\\'))
            {
                if (key.Length == 0) continue;

                tvItem = FindKey(tvItem, key);
                if (tvItem == IntPtr.Zero)
                {
                    return;
                }
                Interop.SendMessage(wndTreeView, Interop.TVM.SELECTITEM, TVGN_CARET, tvItem);

                // expand tree node 
                const int VK_RIGHT = 0x27;
                Interop.SendMessage(wndTreeView, Interop.WM.KEYDOWN, VK_RIGHT, 0);
                Interop.SendMessage(wndTreeView, Interop.WM.KEYUP, VK_RIGHT, 0);
            }

            Interop.SendMessage(wndTreeView, Interop.TVM.SELECTITEM, TVGN_CARET, tvItem);

            if (select)
            {
                Interop.BringWindowToTop(wndApp);
            }
            else
            {
                SendTabKey(false);
            }
        }

        private void OpenValue(string value)
        {
            if (value == null || value.Length == 0) return;

            Interop.SendMessage(wndListView, Interop.WM.SETFOCUS, 0, 0);

            if (value.Length == 0)
            {
                SetLVItemState(0);
                return;
            }

            int item = 0;
            for (;;)
            {
                string itemText = GetLVItemText(item);
                if (itemText == null)
                {
                    return;
                }
                if (string.Compare(itemText, value, true) == 0)
                {
                    break;
                }
                item++;
            }

            SetLVItemState(item);


            const int LVM_FIRST = 0x1000;
            const int LVM_ENSUREVISIBLE = (LVM_FIRST + 19);
            Interop.SendMessage(wndListView, LVM_ENSUREVISIBLE, item, 0);

            Interop.BringWindowToTop(wndApp);

            SendTabKey(false);
            SendTabKey(true);
        }
        

        private static bool found;
        private void Dispose(bool disposing)
        {
            if (disposing)
            {
            }

            if (lpLocalBuffer != IntPtr.Zero)
                Marshal.FreeHGlobal(lpLocalBuffer);
            if (lpRemoteBuffer != IntPtr.Zero)
                Interop.VirtualFreeEx(hProcess, lpRemoteBuffer, 0, Interop.MEM_RELEASE);
            if (hProcess != IntPtr.Zero)
                Interop.CloseHandle(hProcess);
        }

        private const int dwBufferSize = 1024;

        private IntPtr wndApp;
        private IntPtr wndTreeView;
        private IntPtr wndListView;

        private IntPtr hProcess = IntPtr.Zero;
        private IntPtr lpRemoteBuffer = IntPtr.Zero;
        private IntPtr lpLocalBuffer = IntPtr.Zero;
        private static IntPtr wndApp1;
        

        private void SendTabKey(bool shiftPressed)
        {
            const int VK_TAB = 0x09;
            const int VK_SHIFT = 0x10;
            if (!shiftPressed)
            {
                Interop.PostMessage(wndApp, Interop.WM.KEYDOWN, VK_TAB, 0x1f01);
                Interop.PostMessage(wndApp, Interop.WM.KEYUP, VK_TAB, 0x1f01);
            }
            else
            {
                Interop.PostMessage(wndApp, Interop.WM.KEYDOWN, VK_SHIFT, 0x1f01);
                Interop.PostMessage(wndApp, Interop.WM.KEYDOWN, VK_TAB, 0x1f01);
                Interop.PostMessage(wndApp, Interop.WM.KEYUP, VK_TAB, 0x1f01);
                Interop.PostMessage(wndApp, Interop.WM.KEYUP, VK_SHIFT, 0x1f01);
            }
        }


        private string GetTVItemTextEx(IntPtr wndTreeView, IntPtr item)
        {
            const int TVIF_TEXT = 0x0001;
            const int MAX_TVITEMTEXT = 512;

            Interop.TVITEM tvi = new Interop.TVITEM();
            tvi.mask = TVIF_TEXT;
            tvi.hItem = item;
            tvi.cchTextMax = MAX_TVITEMTEXT;
            // set address to remote buffer immediately following the tvItem

            tvi.pszText = (IntPtr)(lpRemoteBuffer.ToInt64() + Marshal.SizeOf(typeof(Interop.TVITEM)));

            // copy local tvItem to remote buffer
            bool bSuccess = Interop.WriteProcessMemory(hProcess, lpRemoteBuffer, ref tvi, Marshal.SizeOf(typeof(Interop.TVITEM)), IntPtr.Zero);
            if (!bSuccess)
                throw new SystemException("Failed to write to process memory");

            bool res = Interop.SendMessage(wndTreeView, Interop.TVM.GETITEMW, 0, lpRemoteBuffer);

            // copy tvItem back into local buffer (copy whole buffer because we don't yet know how big the string is)
            bSuccess = Interop.ReadProcessMemory(hProcess, lpRemoteBuffer, lpLocalBuffer, dwBufferSize, IntPtr.Zero);
            if (!bSuccess)
                throw new SystemException("Failed to read from process memory");

            return Marshal.PtrToStringUni((IntPtr)(lpLocalBuffer.ToInt64() + Marshal.SizeOf(typeof(Interop.TVITEM))));
        }

        private IntPtr FindKey(IntPtr itemParent, string key)
        {
            found = false;
            IntPtr itemChild = Interop.SendMessage(wndTreeView, Interop.TVM.GETNEXTITEM, Interop.TVGN.CHILD, itemParent);
            while (itemChild != IntPtr.Zero)
            {
                if (string.Compare(GetTVItemTextEx(wndTreeView, itemChild), key, true) == 0)
                {
                    found = true;
                    return itemChild;
                }
                itemChild = Interop.SendMessage(wndTreeView, Interop.TVM.GETNEXTITEM, Interop.TVGN.NEXT, itemChild);
            }
            Console.WriteLine(string.Format("key '{0}' not found!", key));

            return IntPtr.Zero;
        }

        private void SetLVItemState(int item)
        {
            const int LVM_FIRST = 0x1000;
            const int LVM_SETITEMSTATE = (LVM_FIRST + 43);
            const int LVIF_STATE = 0x0008;

            const int LVIS_FOCUSED = 0x0001;
            const int LVIS_SELECTED = 0x0002;

            Interop.LVITEM lvItem = new Interop.LVITEM();
            lvItem.mask = LVIF_STATE;
            lvItem.iItem = item;
            lvItem.iSubItem = 0;

            lvItem.state = LVIS_FOCUSED | LVIS_SELECTED;
            lvItem.stateMask = LVIS_FOCUSED | LVIS_SELECTED;

            // copy local lvItem to remote buffer
            bool bSuccess = Interop.WriteProcessMemory(hProcess, lpRemoteBuffer, ref lvItem, Marshal.SizeOf(typeof(Interop.LVITEM)), IntPtr.Zero);
            if (!bSuccess)
                throw new SystemException("Failed to write to process memory");

            // Send the message to the remote window with the address of the remote buffer
            bSuccess = Interop.SendMessage(wndListView, LVM_SETITEMSTATE, item, lpRemoteBuffer);
            if (!bSuccess)
                throw new SystemException("LVM_GETITEM Failed ");
        }

        private string GetLVItemText(int item)
        {
            const int LVM_GETITEM = 0x1005;
            const int LVIF_TEXT = 0x0001;

            Interop.LVITEM lvItem = new Interop.LVITEM();
            lvItem.mask = LVIF_TEXT;
            lvItem.iItem = item;
            lvItem.iSubItem = 0;
            // set address to remote buffer immediately following the lvItem 
            lvItem.pszText = (IntPtr)(lpRemoteBuffer.ToInt64() + Marshal.SizeOf(typeof(Interop.LVITEM)));
            lvItem.cchTextMax = 50;

            // copy local lvItem to remote buffer
            bool bSuccess = Interop.WriteProcessMemory(hProcess, lpRemoteBuffer, ref lvItem, Marshal.SizeOf(typeof(Interop.LVITEM)), IntPtr.Zero);
            if (!bSuccess)
                throw new SystemException("Failed to write to process memory");

            // Send the message to the remote window with the address of the remote buffer
            bSuccess = Interop.SendMessage(wndListView, LVM_GETITEM, 0, lpRemoteBuffer);
            if (!bSuccess)
                return null;

            // copy lvItem back into local buffer (copy whole buffer because we don't yet know how big the string is)
            bSuccess = Interop.ReadProcessMemory(hProcess, lpRemoteBuffer, lpLocalBuffer, dwBufferSize, IntPtr.Zero);
            if (!bSuccess)
                throw new SystemException("Failed to read from process memory");

            return Marshal.PtrToStringAnsi((IntPtr)(lpLocalBuffer.ToInt64() + Marshal.SizeOf(typeof(Interop.LVITEM))));
        }


        private class Interop
        {

            #region structs

            /// <summary>
            /// from 'http://dotnetjunkies.com/WebLog/chris.taylor/'
            /// </summary>
            [StructLayout(LayoutKind.Sequential)]
            public struct LVITEM
            {
                public uint mask;
                public int iItem;
                public int iSubItem;
                public uint state;
                public uint stateMask;
                public IntPtr pszText;
                public int cchTextMax;
                public int iImage;
            }

            /// <summary>
            /// from '.\PlatformSDK\Include\commctrl.h'
            /// </summary>
            [StructLayout(LayoutKind.Sequential)]
            internal struct TVITEM
            {
                public uint mask;
                public IntPtr hItem;
                public uint state;
                public uint stateMask;
                public IntPtr pszText;
                public int cchTextMax;
                public uint iImage;
                public uint iSelectedImage;
                public uint cChildren;
                public IntPtr lParam;
            }
            #endregion
            


            [DllImport("user32.dll")]
            internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

            [DllImport("user32.dll", CharSet = CharSet.Auto)]
            internal static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);

            [DllImport("kernel32")]
            internal static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

            [DllImport("user32.dll")]
            internal static extern uint WaitForInputIdle(IntPtr hProcess, uint dwMilliseconds);

            [DllImport("kernel32")]
            internal static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, int dwSize, uint flAllocationType, uint flProtect);

            [DllImport("kernel32")]
            internal static extern bool VirtualFreeEx(IntPtr hProcess, IntPtr lpAddress, int dwSize, uint dwFreeType);

            [DllImport("kernel32")]
            internal static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, ref LVITEM buffer, int dwSize, IntPtr lpNumberOfBytesWritten);

            [DllImport("kernel32")]
            internal static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, ref TVITEM buffer, int dwSize, IntPtr lpNumberOfBytesWritten);

            [DllImport("kernel32")]
            internal static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, IntPtr lpBuffer, int dwSize, IntPtr lpNumberOfBytesRead);

            [DllImport("kernel32")]
            internal static extern bool CloseHandle(IntPtr hObject);


            internal const uint PROCESS_ALL_ACCESS = (uint)(0x000F0000L | 0x00100000L | 0xFFF);
            internal const uint MEM_COMMIT = 0x1000;
            internal const uint MEM_RELEASE = 0x8000;
            internal const uint PAGE_READWRITE = 0x04;



            /// <summary>
            /// from '.\PlatformSDK\Include\WinUser.h'
            /// </summary>
            internal enum WM : int
            {
                NULL = 0x0000,
                CREATE = 0x0001,
                DESTROY = 0x0002,
                MOVE = 0x0003,
                SIZE = 0x0005,
                ACTIVATE = 0x0006,
                SETFOCUS = 0x0007,
                KILLFOCUS = 0x0008,
                ENABLE = 0x000A,
                SETREDRAW = 0x000B,
                SETTEXT = 0x000C,
                GETTEXT = 0x000D,
                GETTEXTLENGTH = 0x000E,
                PAINT = 0x000F,
                CLOSE = 0x0010,
                QUERYENDSESSION = 0x0011,
                QUIT = 0x0012,
                QUERYOPEN = 0x0013,
                ERASEBKGND = 0x0014,
                SYSCOLORCHANGE = 0x0015,
                ENDSESSION = 0x0016,
                SHOWWINDOW = 0x0018,
                CTLCOLOR = 0x0019,
                WININICHANGE = 0x001A,
                SETTINGCHANGE = 0x001A,
                DEVMODECHANGE = 0x001B,
                ACTIVATEAPP = 0x001C,
                FONTCHANGE = 0x001D,
                TIMECHANGE = 0x001E,
                CANCELMODE = 0x001F,
                SETCURSOR = 0x0020,
                MOUSEACTIVATE = 0x0021,
                CHILDACTIVATE = 0x0022,
                QUEUESYNC = 0x0023,
                GETMINMAXINFO = 0x0024,
                PAINTICON = 0x0026,
                ICONERASEBKGND = 0x0027,
                NEXTDLGCTL = 0x0028,
                SPOOLERSTATUS = 0x002A,
                DRAWITEM = 0x002B,
                MEASUREITEM = 0x002C,
                DELETEITEM = 0x002D,
                VKEYTOITEM = 0x002E,
                CHARTOITEM = 0x002F,
                SETFONT = 0x0030,
                GETFONT = 0x0031,
                SETHOTKEY = 0x0032,
                GETHOTKEY = 0x0033,
                QUERYDRAGICON = 0x0037,
                COMPAREITEM = 0x0039,
                GETOBJECT = 0x003D,
                COMPACTING = 0x0041,
                COMMNOTIFY = 0x0044,
                WINDOWPOSCHANGING = 0x0046,
                WINDOWPOSCHANGED = 0x0047,
                POWER = 0x0048,
                COPYDATA = 0x004A,
                CANCELJOURNAL = 0x004B,
                NOTIFY = 0x004E,
                INPUTLANGCHANGEREQUEST = 0x0050,
                INPUTLANGCHANGE = 0x0051,
                TCARD = 0x0052,
                HELP = 0x0053,
                USERCHANGED = 0x0054,
                NOTIFYFORMAT = 0x0055,
                CONTEXTMENU = 0x007B,
                STYLECHANGING = 0x007C,
                STYLECHANGED = 0x007D,
                DISPLAYCHANGE = 0x007E,
                GETICON = 0x007F,
                SETICON = 0x0080,
                NCCREATE = 0x0081,
                NCDESTROY = 0x0082,
                NCCALCSIZE = 0x0083,
                NCHITTEST = 0x0084,
                NCPAINT = 0x0085,
                NCACTIVATE = 0x0086,
                GETDLGCODE = 0x0087,
                SYNCPAINT = 0x0088,
                NCMOUSEMOVE = 0x00A0,
                NCLBUTTONDOWN = 0x00A1,
                NCLBUTTONUP = 0x00A2,
                NCLBUTTONDBLCLK = 0x00A3,
                NCRBUTTONDOWN = 0x00A4,
                NCRBUTTONUP = 0x00A5,
                NCRBUTTONDBLCLK = 0x00A6,
                NCMBUTTONDOWN = 0x00A7,
                NCMBUTTONUP = 0x00A8,
                NCMBUTTONDBLCLK = 0x00A9,
                KEYDOWN = 0x0100,
                KEYUP = 0x0101,
                CHAR = 0x0102,
                DEADCHAR = 0x0103,
                SYSKEYDOWN = 0x0104,
                SYSKEYUP = 0x0105,
                SYSCHAR = 0x0106,
                SYSDEADCHAR = 0x0107,
                KEYLAST = 0x0108,
                IME_STARTCOMPOSITION = 0x010D,
                IME_ENDCOMPOSITION = 0x010E,
                IME_COMPOSITION = 0x010F,
                IME_KEYLAST = 0x010F,
                INITDIALOG = 0x0110,
                COMMAND = 0x0111,
                SYSCOMMAND = 0x0112,
                TIMER = 0x0113,
                HSCROLL = 0x0114,
                VSCROLL = 0x0115,
                INITMENU = 0x0116,
                INITMENUPOPUP = 0x0117,
                MENUSELECT = 0x011F,
                MENUCHAR = 0x0120,
                ENTERIDLE = 0x0121,
                MENURBUTTONUP = 0x0122,
                MENUDRAG = 0x0123,
                MENUGETOBJECT = 0x0124,
                UNINITMENUPOPUP = 0x0125,
                MENUCOMMAND = 0x0126,
                CHANGEUISTATE = 0x0127,
                UPDATEUISTATE = 0x0128,
                QUERYUISTATE = 0x0129,
                CTLCOLORMSGBOX = 0x0132,
                CTLCOLOREDIT = 0x0133,
                CTLCOLORLISTBOX = 0x0134,
                CTLCOLORBTN = 0x0135,
                CTLCOLORDLG = 0x0136,
                CTLCOLORSCROLLBAR = 0x0137,
                CTLCOLORSTATIC = 0x0138,
                MOUSEMOVE = 0x0200,
                LBUTTONDOWN = 0x0201,
                LBUTTONUP = 0x0202,
                LBUTTONDBLCLK = 0x0203,
                RBUTTONDOWN = 0x0204,
                RBUTTONUP = 0x0205,
                RBUTTONDBLCLK = 0x0206,
                MBUTTONDOWN = 0x0207,
                MBUTTONUP = 0x0208,
                MBUTTONDBLCLK = 0x0209,
                MOUSEWHEEL = 0x020A,
                PARENTNOTIFY = 0x0210,
                ENTERMENULOOP = 0x0211,
                EXITMENULOOP = 0x0212,
                NEXTMENU = 0x0213,
                SIZING = 0x0214,
                CAPTURECHANGED = 0x0215,
                MOVING = 0x0216,
                DEVICECHANGE = 0x0219,
                MDICREATE = 0x0220,
                MDIDESTROY = 0x0221,
                MDIACTIVATE = 0x0222,
                MDIRESTORE = 0x0223,
                MDINEXT = 0x0224,
                MDIMAXIMIZE = 0x0225,
                MDITILE = 0x0226,
                MDICASCADE = 0x0227,
                MDIICONARRANGE = 0x0228,
                MDIGETACTIVE = 0x0229,
                MDISETMENU = 0x0230,
                ENTERSIZEMOVE = 0x0231,
                EXITSIZEMOVE = 0x0232,
                DROPFILES = 0x0233,
                MDIREFRESHMENU = 0x0234,
                IME_SETCONTEXT = 0x0281,
                IME_NOTIFY = 0x0282,
                IME_CONTROL = 0x0283,
                IME_COMPOSITIONFULL = 0x0284,
                IME_SELECT = 0x0285,
                IME_CHAR = 0x0286,
                IME_REQUEST = 0x0288,
                IME_KEYDOWN = 0x0290,
                IME_KEYUP = 0x0291,
                MOUSEHOVER = 0x02A1,
                MOUSELEAVE = 0x02A3,
                CUT = 0x0300,
                COPY = 0x0301,
                PASTE = 0x0302,
                CLEAR = 0x0303,
                UNDO = 0x0304,
                RENDERFORMAT = 0x0305,
                RENDERALLFORMATS = 0x0306,
                DESTROYCLIPBOARD = 0x0307,
                DRAWCLIPBOARD = 0x0308,
                PAINTCLIPBOARD = 0x0309,
                VSCROLLCLIPBOARD = 0x030A,
                SIZECLIPBOARD = 0x030B,
                ASKCBFORMATNAME = 0x030C,
                CHANGECBCHAIN = 0x030D,
                HSCROLLCLIPBOARD = 0x030E,
                QUERYNEWPALETTE = 0x030F,
                PALETTEISCHANGING = 0x0310,
                PALETTECHANGED = 0x0311,
                HOTKEY = 0x0312,
                PRINT = 0x0317,
                PRINTCLIENT = 0x0318,
                HANDHELDFIRST = 0x0358,
                HANDHELDLAST = 0x035F,
                AFXFIRST = 0x0360,
                AFXLAST = 0x037F,
                PENWINFIRST = 0x0380,
                PENWINLAST = 0x038F,
                APP = 0x8000,
                USER = 0x0400,
            }

            /// <summary>
            /// from '.\PlatformSDK\Include\CommCtrl.h'
            /// </summary>
            internal enum Base : int
            {
                LVM = 0x1000,
                TV = 0x1100,
                HDM = 0x1200,
                TCM = 0x1300,
                PGM = 0x1400,
                ECM = 0x1500,
                BCM = 0x1600,
                CBM = 0x1700,
                CCM = 0x2000,
                NM = 0x0000,
                LVN = NM - 100,
                HDN = NM - 300,
                EM = 0x400,
            }



            /// <summary>
            /// from '.\PlatformSDK\Include\CommCtrl.h'
            /// </summary>
            internal enum TVM : int
            {
                FIRST = Base.TV,
                INSERTITEMA = FIRST + 0,
                DELETEITEM = FIRST + 1,
                EXPAND = FIRST + 2,
                GETITEMRECT = FIRST + 4,
                GETCOUNT = FIRST + 5,
                GETINDENT = FIRST + 6,
                SETINDENT = FIRST + 7,
                GETIMAGELIST = FIRST + 8,
                SETIMAGELIST = FIRST + 9,
                GETNEXTITEM = FIRST + 10,
                SELECTITEM = FIRST + 11,
                GETITEMA = FIRST + 12,
                SETITEMA = FIRST + 13,
                EDITLABELA = FIRST + 14,
                GETEDITCONTROL = FIRST + 15,
                GETVISIBLECOUNT = FIRST + 16,
                HITTEST = FIRST + 17,
                CREATEDRAGIMAGE = FIRST + 18,
                SORTCHILDREN = FIRST + 19,
                ENSUREVISIBLE = FIRST + 20,
                SORTCHILDRENCB = FIRST + 21,
                ENDEDITLABELNOW = FIRST + 22,
                GETISEARCHSTRINGA = FIRST + 23,
                SETTOOLTIPS = FIRST + 24,
                GETTOOLTIPS = FIRST + 25,
                SETINSERTMARK = FIRST + 26,
                SETITEMHEIGHT = FIRST + 27,
                GETITEMHEIGHT = FIRST + 28,
                SETBKCOLOR = FIRST + 29,
                SETTEXTCOLOR = FIRST + 30,
                GETBKCOLOR = FIRST + 31,
                GETTEXTCOLOR = FIRST + 32,
                SETSCROLLTIME = FIRST + 33,
                GETSCROLLTIME = FIRST + 34,
                SETINSERTMARKCOLOR = FIRST + 37,
                GETINSERTMARKCOLOR = FIRST + 38,
                GETITEMSTATE = FIRST + 39,
                SETLINECOLOR = FIRST + 40,
                GETLINECOLOR = FIRST + 41,
                MAPACCIDTOHTREEITEM = FIRST + 42,
                MAPHTREEITEMTOACCID = FIRST + 43,
                INSERTITEMW = FIRST + 50,
                GETITEMW = FIRST + 62,
                SETITEMW = FIRST + 63,
                GETISEARCHSTRINGW = FIRST + 64,
                EDITLABELW = FIRST + 65
            }

            internal enum TVE : int
            {
                COLLAPSE = 0x0001,
                EXPAND = 0x0002,
                TOGGLE = 0x0003,
                EXPANDPARTIAL = 0x4000,
                COLLAPSERESET = 0x8000
            }

            /// <summary>
            /// from '.\PlatformSDK\Include\CommCtrl.h'
            /// </summary>
            internal enum TVGN : int
            {
                ROOT = 0x0000,
                NEXT = 0x0001,
                PREVIOUS = 0x0002,
                PARENT = 0x0003,
                CHILD = 0x0004,
                FIRSTVISIBLE = 0x0005,
                NEXTVISIBLE = 0x0006,
                PREVIOUSVISIBLE = 0x0007,
                DROPHILITE = 0x0008,
                CARET = 0x0009,
                LASTVISIBLE = 0x000A
            }

            [DllImport("user32.dll")]
            internal static extern int SendMessage(IntPtr hWnd, WM msg, int wParam, int lParam);

            [DllImport("user32.dll")]
            internal static extern IntPtr SendMessage(IntPtr hWnd, TVM msg, TVGN wParam, IntPtr lParam);

            [DllImport("user32.dll")]
            internal static extern bool SendMessage(IntPtr hWnd, TVM msg, TVE wParam, IntPtr lParam);

            [DllImport("user32.dll")]
            internal static extern bool SendMessage(IntPtr hWnd, TVM msg, int wParam, IntPtr lParam);

            [DllImport("user32.dll")]
            internal static extern bool BringWindowToTop(IntPtr hWnd);

            [DllImport("user32.dll")]
            internal static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

            [DllImport("user32.dll")]
            internal static extern bool SendMessage(IntPtr hWnd, Int32 msg, Int32 wParam, IntPtr lParam);

            [DllImport("user32.dll")]
            internal static extern int SendMessage(IntPtr hWnd, Int32 msg, Int32 wParam, Int32 lParam);

            [DllImport("user32.dll")]
            internal static extern int PostMessage(IntPtr hWnd, WM msg, Int32 wParam, Int32 lParam);

            [DllImport("user32.dll")]
            internal static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        }

        #endregion
    }
}



"@
[xml]$WPF=@"
<Window
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        Title="Locate RegKey" Height="350" Width="525">
    <Grid>
        <DataGrid x:Name="Data" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" AutoGenerateColumns="True"></DataGrid>
    </Grid>
</Window>



"@

$Script:KeyList=@()

Function Add-Key
{
    [CmdletBinding()]
    [Alias()]
    [OutputType([void])]
    Param
    (
        
        [Parameter(Mandatory=$true)]
        $FriendlyName,

        
        [Parameter(Mandatory=$true)]
        [string]$KeyPath,

        [string]$Description=$Null,
        [string] $Value=$Null
    )

    
    Process
    {
    $obj=New-Object -TypeName psobject -Property @{"Name"=$FriendlyName;"Description"=$Description;"Path"=$KeyPath;"Value"=$Value}
    $Script:KeyList+=$obj
    }
   
}


function Open-Key
{
    [CmdletBinding()]
    Param
    ([Parameter(Mandatory=$true)]$Name)

    Process
    {

    
    $obj=$KeyList[$KeyList.name.indexof($Name)]
    $Path=$obj.Path
    $Value=$obj.Value

    

    if($Path -ne $Null)
    {
    [Registry.KeyLocator]::Locate($Path,$Value)
    }
    else
    {
    write-host "Path can not be Null"
    }
    }
    
}


#import the C# Code
Add-Type $code -Language CSharp 


#Add Common registry keys to a list 
#not if you use the -value setting will open a value in a key
Add-Key -FriendlyName "I.E Settings User" -Description "Users Internet Explorer Settings" -KeyPath "HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings"
Add-Key -FriendlyName "I.E Settings Machine" -Description "Machine Internet Explorer Settings" -KeyPath "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings"
Add-Key -FriendlyName "Auto Logon Machine" -Description "Admin Machine Autologon Settings" -KeyPath "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

#Load xml form data
$reader=(New-Object System.Xml.XmlNodeReader $WPF)
$Window=[Windows.Markup.XamlReader]::Load( $reader )

#Connect to Controls 

  $WPF.SelectNodes("//*[@*[contains(translate(name(.),'n','N'),'Name')]]")  | ForEach {

  New-Variable  -Name $_.Name -Value $Window.FindName($_.Name) -Force

  } 
  
  #Add psobects to a collection to show in form
  $a = New-Object -TypeName System.Collections.ObjectModel.ObservableCollection[object]
    $Script:KeyList | ForEach-Object -Process {
        $a.Add((
                New-Object -TypeName PSObject -Property @{
                    Name         = $_.Name;
                    Description  = $_.Description
                }
        ))      
    }
 
 
 #Set Columns to fill datagrid
  $Data.add_AutoGeneratingColumn({$_.Column.Width = New-Object System.Windows.Controls.DataGridLength(1, [System.Windows.Controls.DataGridLengthUnitType]::Star)})
  #Add data source
  $Data.ItemsSource=$a
  #Add event to open key
  $data.add_BeginningEdit({Open-Key -Name $_.EditingEventArgs.Source.DataContext.Name })
  #show form a double click will launch regedit and find the key
  $Null = $Window.ShowDialog() 


#can be used with out-gridview
#$key=$Script:KeyList|select name ,Description|Out-GridView -Title "Select Key To Open & Click OK"  -PassThru 
#Open-Key -Name $key.Name 





