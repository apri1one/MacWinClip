using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Threading;

namespace MacWinClip
{
    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    public sealed class LazyFileDataObject : IDataObject
    {
        private const int S_OK = 0;
        private const int S_FALSE = 1;
        private const int E_NOTIMPL = unchecked((int)0x80004001);
        private const int OLE_E_ADVISENOTSUPPORTED = unchecked((int)0x80040003);
        private const int DV_E_FORMATETC = unchecked((int)0x80040064);
        private const int DV_E_TYMED = unchecked((int)0x80040069);
        private const int GMEM_MOVEABLE = 0x0002;
        private const int GMEM_ZEROINIT = 0x0040;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        private const uint FD_ATTRIBUTES = 0x00000004;
        private const uint FD_FILESIZE = 0x00000040;
        private const uint STGM_READ = 0x00000000;
        private const uint STGM_SHARE_DENY_NONE = 0x00000040;
        private const uint DROPEFFECT_COPY = 1;

        private static readonly short FileDescriptorFormat =
            unchecked((short)RegisterClipboardFormat("FileGroupDescriptorW"));
        private static readonly short FileContentsFormat =
            unchecked((short)RegisterClipboardFormat("FileContents"));
        private static readonly short PreferredDropEffectFormat =
            unchecked((short)RegisterClipboardFormat("Preferred DropEffect"));

        private readonly string messageId;
        private readonly string[] names;
        private readonly long[] sizes;
        private readonly string demandRoot;
        private readonly string destinationRoot;
        private readonly string progressScript;
        private readonly string progressRoot;
        private readonly string cancelRoot;
        private readonly object requestLock = new object();
        private bool requested;

        public LazyFileDataObject(
            string messageId,
            string[] names,
            long[] sizes,
            string demandRoot,
            string destinationRoot,
            string progressScript,
            string progressRoot,
            string cancelRoot)
        {
            if (
                String.IsNullOrEmpty(messageId) ||
                names == null ||
                sizes == null ||
                names.Length == 0 ||
                names.Length != sizes.Length)
            {
                throw new ArgumentException("Invalid lazy file offer.");
            }
            this.messageId = messageId;
            this.names = names;
            this.sizes = sizes;
            this.demandRoot = demandRoot;
            this.destinationRoot = destinationRoot;
            this.progressScript = progressScript;
            this.progressRoot = progressRoot;
            this.cancelRoot = cancelRoot;
        }

        public void GetData(ref FORMATETC format, out STGMEDIUM medium)
        {
            medium = new STGMEDIUM();
            if (format.cfFormat == FileDescriptorFormat)
            {
                if ((format.tymed & TYMED.TYMED_HGLOBAL) == 0)
                {
                    throw new COMException("Unsupported descriptor medium.", DV_E_TYMED);
                }
                medium.tymed = TYMED.TYMED_HGLOBAL;
                medium.unionmember = BuildFileGroupDescriptor();
                medium.pUnkForRelease = null;
                return;
            }

            if (format.cfFormat == PreferredDropEffectFormat)
            {
                if ((format.tymed & TYMED.TYMED_HGLOBAL) == 0)
                {
                    throw new COMException("Unsupported drop-effect medium.", DV_E_TYMED);
                }
                medium.tymed = TYMED.TYMED_HGLOBAL;
                medium.unionmember = BuildUInt32(DROPEFFECT_COPY);
                medium.pUnkForRelease = null;
                return;
            }

            if (format.cfFormat == FileContentsFormat)
            {
                if ((format.tymed & TYMED.TYMED_ISTREAM) == 0)
                {
                    throw new COMException("Unsupported file-content medium.", DV_E_TYMED);
                }
                if (format.lindex < 0 || format.lindex >= names.Length)
                {
                    throw new COMException("Invalid file index.", DV_E_FORMATETC);
                }

                string path = WaitForFile(format.lindex);
                IStream stream;
                int result = SHCreateStreamOnFileEx(
                    path,
                    STGM_READ | STGM_SHARE_DENY_NONE,
                    0,
                    false,
                    null,
                    out stream);
                if (result != S_OK || stream == null)
                {
                    Marshal.ThrowExceptionForHR(result);
                }

                medium.tymed = TYMED.TYMED_ISTREAM;
                medium.unionmember = Marshal.GetComInterfaceForObject(
                    stream,
                    typeof(IStream));
                medium.pUnkForRelease = null;
                return;
            }

            throw new COMException("Unsupported clipboard format.", DV_E_FORMATETC);
        }

        public void GetDataHere(ref FORMATETC format, ref STGMEDIUM medium)
        {
            throw new COMException("GetDataHere is not supported.", E_NOTIMPL);
        }

        public int QueryGetData(ref FORMATETC format)
        {
            if (
                format.dwAspect != DVASPECT.DVASPECT_CONTENT ||
                format.ptd != IntPtr.Zero)
            {
                return DV_E_FORMATETC;
            }
            if (
                format.cfFormat == FileDescriptorFormat &&
                (format.tymed & TYMED.TYMED_HGLOBAL) != 0)
            {
                return S_OK;
            }
            if (
                format.cfFormat == PreferredDropEffectFormat &&
                (format.tymed & TYMED.TYMED_HGLOBAL) != 0)
            {
                return S_OK;
            }
            if (
                format.cfFormat == FileContentsFormat &&
                (format.tymed & TYMED.TYMED_ISTREAM) != 0 &&
                format.lindex >= 0 &&
                format.lindex < names.Length)
            {
                return S_OK;
            }
            return DV_E_FORMATETC;
        }

        public int GetCanonicalFormatEtc(ref FORMATETC formatIn, out FORMATETC formatOut)
        {
            formatOut = formatIn;
            formatOut.ptd = IntPtr.Zero;
            return unchecked((int)0x00040130);
        }

        public void SetData(ref FORMATETC format, ref STGMEDIUM medium, bool release)
        {
            throw new COMException("SetData is not supported.", E_NOTIMPL);
        }

        public IEnumFORMATETC EnumFormatEtc(DATADIR direction)
        {
            if (direction != DATADIR.DATADIR_GET)
            {
                throw new COMException("Only DATADIR_GET is supported.", E_NOTIMPL);
            }
            return new FormatEnumerator(new[]
            {
                MakeFormat(FileDescriptorFormat, TYMED.TYMED_HGLOBAL, -1),
                MakeFormat(FileContentsFormat, TYMED.TYMED_ISTREAM, -1),
                MakeFormat(PreferredDropEffectFormat, TYMED.TYMED_HGLOBAL, -1)
            });
        }

        public int DAdvise(
            ref FORMATETC format,
            ADVF advf,
            IAdviseSink adviseSink,
            out int connection)
        {
            connection = 0;
            return OLE_E_ADVISENOTSUPPORTED;
        }

        public void DUnadvise(int connection)
        {
            throw new COMException("Advisory connections are not supported.", OLE_E_ADVISENOTSUPPORTED);
        }

        public int EnumDAdvise(out IEnumSTATDATA enumAdvise)
        {
            enumAdvise = null;
            return OLE_E_ADVISENOTSUPPORTED;
        }

        private static FORMATETC MakeFormat(short clipboardFormat, TYMED medium, int index)
        {
            return new FORMATETC
            {
                cfFormat = clipboardFormat,
                dwAspect = DVASPECT.DVASPECT_CONTENT,
                lindex = index,
                ptd = IntPtr.Zero,
                tymed = medium
            };
        }

        private string WaitForFile(int index)
        {
            EnsureRequested();
            string done = Path.Combine(demandRoot, messageId + ".done");
            string failed = Path.Combine(demandRoot, messageId + ".failed");
            string canceled = Path.Combine(demandRoot, messageId + ".canceled");
            string path = Path.Combine(
                Path.Combine(destinationRoot, messageId),
                names[index]);
            DateTime deadline = DateTime.UtcNow.AddHours(8);

            while (DateTime.UtcNow < deadline)
            {
                if (File.Exists(failed))
                {
                    throw new COMException("MacWinClip file transfer failed.");
                }
                if (File.Exists(canceled))
                {
                    throw new COMException("MacWinClip file transfer was canceled.");
                }
                if (File.Exists(done))
                {
                    if (!File.Exists(path) || new FileInfo(path).Length != sizes[index])
                    {
                        throw new COMException("Transferred file is missing or has the wrong size.");
                    }
                    return path;
                }
                Thread.Sleep(100);
            }
            throw new COMException("MacWinClip file transfer timed out.");
        }

        private void EnsureRequested()
        {
            lock (requestLock)
            {
                if (requested)
                {
                    return;
                }
                Directory.CreateDirectory(demandRoot);
                string request = Path.Combine(demandRoot, messageId + ".request");
                string temporary = request + ".tmp";
                File.WriteAllText(temporary, "fetch");
                if (File.Exists(request))
                {
                    File.Delete(temporary);
                }
                else
                {
                    File.Move(temporary, request);
                }
                requested = true;
                StartProgressWindow();
            }
        }

        private void StartProgressWindow()
        {
            string state = Path.Combine(progressRoot, messageId + ".json");
            string shown = Path.Combine(progressRoot, messageId + ".shown");
            string cancel = Path.Combine(cancelRoot, messageId + ".request");
            try
            {
                Directory.CreateDirectory(progressRoot);
                Directory.CreateDirectory(cancelRoot);
                File.WriteAllText(shown, "shown");
                ProcessStartInfo start = new ProcessStartInfo
                {
                    FileName = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                        @"System32\WindowsPowerShell\v1.0\powershell.exe"),
                    Arguments =
                        "-NoProfile -Sta -ExecutionPolicy Bypass -File " +
                        QuoteArgument(progressScript) +
                        " -StateFile " +
                        QuoteArgument(state) +
                        " -CancelFile " +
                        QuoteArgument(cancel),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                Process.Start(start);
            }
            catch
            {
                try
                {
                    File.Delete(shown);
                }
                catch
                {
                }
            }
        }

        private static string QuoteArgument(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private IntPtr BuildFileGroupDescriptor()
        {
            int descriptorSize = Marshal.SizeOf(typeof(FILEDESCRIPTORW));
            int totalSize = sizeof(uint) + descriptorSize * names.Length;
            IntPtr handle = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, new UIntPtr((uint)totalSize));
            if (handle == IntPtr.Zero)
            {
                throw new OutOfMemoryException();
            }
            IntPtr pointer = GlobalLock(handle);
            if (pointer == IntPtr.Zero)
            {
                GlobalFree(handle);
                throw new OutOfMemoryException();
            }
            try
            {
                Marshal.WriteInt32(pointer, names.Length);
                for (int index = 0; index < names.Length; index++)
                {
                    FILEDESCRIPTORW descriptor = new FILEDESCRIPTORW
                    {
                        dwFlags = FD_ATTRIBUTES | FD_FILESIZE,
                        dwFileAttributes = FILE_ATTRIBUTE_NORMAL,
                        nFileSizeHigh = unchecked((uint)(sizes[index] >> 32)),
                        nFileSizeLow = unchecked((uint)sizes[index]),
                        cFileName = names[index]
                    };
                    Marshal.StructureToPtr(
                        descriptor,
                        IntPtr.Add(pointer, sizeof(uint) + index * descriptorSize),
                        false);
                }
            }
            finally
            {
                GlobalUnlock(handle);
            }
            return handle;
        }

        private static IntPtr BuildUInt32(uint value)
        {
            IntPtr handle = GlobalAlloc(
                GMEM_MOVEABLE | GMEM_ZEROINIT,
                new UIntPtr(sizeof(uint)));
            if (handle == IntPtr.Zero)
            {
                throw new OutOfMemoryException();
            }
            IntPtr pointer = GlobalLock(handle);
            if (pointer == IntPtr.Zero)
            {
                GlobalFree(handle);
                throw new OutOfMemoryException();
            }
            try
            {
                Marshal.WriteInt32(pointer, unchecked((int)value));
            }
            finally
            {
                GlobalUnlock(handle);
            }
            return handle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct FILEDESCRIPTORW
        {
            public uint dwFlags;
            public Guid clsid;
            public int sizelCx;
            public int sizelCy;
            public int pointlX;
            public int pointlY;
            public uint dwFileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
            public uint nFileSizeHigh;
            public uint nFileSizeLow;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string cFileName;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint RegisterClipboardFormat(string format);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalAlloc(int flags, UIntPtr bytes);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalLock(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalUnlock(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalFree(IntPtr handle);

        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
        private static extern int SHCreateStreamOnFileEx(
            string fileName,
            uint mode,
            uint attributes,
            [MarshalAs(UnmanagedType.Bool)] bool create,
            IStream template,
            out IStream stream);
    }

    public static class LazyFileClipboard
    {
        [DllImport("ole32.dll")]
        private static extern int OleSetClipboard(IDataObject dataObject);

        public static LazyFileDataObject Set(
            string messageId,
            string[] names,
            long[] sizes,
            string demandRoot,
            string destinationRoot,
            string progressScript,
            string progressRoot,
            string cancelRoot)
        {
            LazyFileDataObject dataObject = new LazyFileDataObject(
                messageId,
                names,
                sizes,
                demandRoot,
                destinationRoot,
                progressScript,
                progressRoot,
                cancelRoot);
            int result = OleSetClipboard(dataObject);
            if (result != 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }
            return dataObject;
        }
    }

    internal sealed class FormatEnumerator : IEnumFORMATETC
    {
        private readonly FORMATETC[] formats;
        private int index;

        public FormatEnumerator(FORMATETC[] formats)
        {
            this.formats = formats;
        }

        private FormatEnumerator(FORMATETC[] formats, int index)
        {
            this.formats = formats;
            this.index = index;
        }

        public int Next(int count, FORMATETC[] elements, int[] fetched)
        {
            int copied = 0;
            while (copied < count && index < formats.Length)
            {
                elements[copied] = formats[index];
                copied++;
                index++;
            }
            if (fetched != null && fetched.Length > 0)
            {
                fetched[0] = copied;
            }
            return copied == count ? 0 : 1;
        }

        public int Skip(int count)
        {
            index = Math.Min(index + count, formats.Length);
            return index < formats.Length ? 0 : 1;
        }

        public int Reset()
        {
            index = 0;
            return 0;
        }

        public void Clone(out IEnumFORMATETC clone)
        {
            clone = new FormatEnumerator(formats, index);
        }
    }
}
