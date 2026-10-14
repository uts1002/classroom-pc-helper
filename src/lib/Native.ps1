# 윈도우 기본 API를 PowerShell에서 쓰기 위한 C# 코드 묶음.
# 외부 프로그램·모듈 없이 소리 장치, 화면 구성, 바탕화면 고정을 다룬다.

if (-not ('PcHelper.Audio' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace PcHelper {

  public class AudioDevice {
    public string Id;
    public string Name;
    public int State;        // 1 사용 가능, 8 선 빠짐(unplugged), 2 사용 안 함, 4 없음
    public bool IsDefault;
  }

  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
  }

  [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceCollection {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int Item(int index, out IMMDevice device);
  }

  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
  }

  [StructLayout(LayoutKind.Sequential)]
  struct PropertyKey { public Guid fmtid; public int pid; }

  // PROPVARIANT는 64비트에서 24바이트다. 크기가 모자라면 메모리가 깨지므로 끝자리를 채워 둔다.
  [StructLayout(LayoutKind.Explicit)]
  struct PropVariant {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr ptr;
    [FieldOffset(16)] public IntPtr pad;
  }

  [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetAt(int index, out PropertyKey key);
    [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
  }

  [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioEndpointVolume {
    [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int GetChannelCount(out int count);
    [PreserveSig] int SetMasterVolumeLevel(float level, ref Guid ctx);
    [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
    [PreserveSig] int GetMasterVolumeLevel(out float level);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    [PreserveSig] int SetChannelVolumeLevel(int ch, float level, ref Guid ctx);
    [PreserveSig] int SetChannelVolumeLevelScalar(int ch, float level, ref Guid ctx);
    [PreserveSig] int GetChannelVolumeLevel(int ch, out float level);
    [PreserveSig] int GetChannelVolumeLevelScalar(int ch, out float level);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
  }

  // 기본 출력 장치를 바꾸는 윈도우 내부 인터페이스. 소리 설정 창이 쓰는 것과 같다.
  // 앞의 10개는 쓰지 않지만 순서를 맞추려고 자리만 둔다.
  [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPolicyConfig {
    [PreserveSig] int Unused1(); [PreserveSig] int Unused2(); [PreserveSig] int Unused3(); [PreserveSig] int Unused4();
    [PreserveSig] int Unused5(); [PreserveSig] int Unused6(); [PreserveSig] int Unused7(); [PreserveSig] int Unused8();
    [PreserveSig] int Unused9(); [PreserveSig] int Unused10();
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
  }

  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom {}
  [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigCom {}

  public static class Audio {
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant v);

    static IMMDeviceEnumerator Enumerator() { return (IMMDeviceEnumerator)new MMDeviceEnumeratorCom(); }

    static string FriendlyName(IMMDevice d) {
      IPropertyStore store;
      if (d.OpenPropertyStore(0, out store) != 0) return "";
      var key = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
      PropVariant v;
      if (store.GetValue(ref key, out v) != 0) return "";
      string name = v.vt == 31 ? Marshal.PtrToStringUni(v.ptr) : "";
      PropVariantClear(ref v);
      return name;
    }

    public static List<AudioDevice> Outputs() {
      var e = Enumerator();
      string defaultId = null;
      IMMDevice def;
      if (e.GetDefaultAudioEndpoint(0, 0, out def) == 0) def.GetId(out defaultId);
      IMMDeviceCollection col;
      var list = new List<AudioDevice>();
      if (e.EnumAudioEndpoints(0, 1 | 8, out col) != 0) return list;
      int n; col.GetCount(out n);
      for (int i = 0; i < n; i++) {
        IMMDevice d; col.Item(i, out d);
        string id; d.GetId(out id);
        int st; d.GetState(out st);
        list.Add(new AudioDevice { Id = id, Name = FriendlyName(d), State = st, IsDefault = id == defaultId });
      }
      return list;
    }

    public static void SetDefault(string id) {
      var p = (IPolicyConfig)new PolicyConfigCom();
      for (int role = 0; role < 3; role++) p.SetDefaultEndpoint(id, role);
    }

    static IAudioEndpointVolume Volume() {
      IMMDevice d;
      if (Enumerator().GetDefaultAudioEndpoint(0, 0, out d) != 0) return null;
      var iid = typeof(IAudioEndpointVolume).GUID;
      object o;
      if (d.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return null;
      return (IAudioEndpointVolume)o;
    }

    public static bool GetMute() { var v = Volume(); bool m = false; if (v != null) v.GetMute(out m); return m; }
    public static void SetMute(bool mute) { var v = Volume(); var g = Guid.Empty; if (v != null) v.SetMute(mute, ref g); }
    public static float GetVolume() { var v = Volume(); float f = -1; if (v != null) v.GetMasterVolumeLevelScalar(out f); return f; }
    public static void SetVolume(float level) { var v = Volume(); var g = Guid.Empty; if (v != null) v.SetMasterVolumeLevelScalar(level, ref g); }
  }

  public static class Display {
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPath, IntPtr paths, ref uint numMode, IntPtr modes, out uint topology);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint numPath, IntPtr paths, uint numMode, IntPtr modes, uint flags);

    // 1 내 화면만, 2 복제, 4 확장, 8 바깥 화면만, 0 알 수 없음
    public static uint Topology() {
      uint np, nm;
      if (GetDisplayConfigBufferSizes(4, out np, out nm) != 0) return 0;
      IntPtr paths = Marshal.AllocHGlobal((int)(np + 1) * 72);
      IntPtr modes = Marshal.AllocHGlobal((int)(nm + 1) * 64);
      uint topology = 0;
      try { if (QueryDisplayConfig(4, ref np, paths, ref nm, modes, out topology) != 0) topology = 0; }
      finally { Marshal.FreeHGlobal(paths); Marshal.FreeHGlobal(modes); }
      return topology;
    }

    public static int Clone()  { return SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero, 0x80 | 0x2); }
    public static int Extend() { return SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero, 0x80 | 0x4); }

    // ── 해상도 ──
    [DllImport("user32.dll", EntryPoint = "QueryDisplayConfig")]
    static extern int QueryActive(uint flags, ref uint numPath, IntPtr paths, ref uint numMode, IntPtr modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(IntPtr packet);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string name, int mode, ref DevMode dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string name, ref DevMode dm, IntPtr hwnd, uint flags, IntPtr param);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DevMode {
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
      public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
      public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
      public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
      public short dmLogPixels;
      public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
      public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    // DisplayConfigGetDeviceInfo 요청 묶음. 머리말(종류·크기·어댑터·대상 번호) 20바이트 뒤에 답이 온다.
    static IntPtr Packet(int type, int size, IntPtr path, int offset) {
      IntPtr p = Marshal.AllocHGlobal(size);
      for (int i = 0; i < size; i++) Marshal.WriteByte(p, i, 0);
      Marshal.WriteInt32(p, 0, type);
      Marshal.WriteInt32(p, 4, size);
      Marshal.WriteInt64(p, 8, Marshal.ReadInt64(path, offset));          // 어댑터 LUID
      Marshal.WriteInt32(p, 16, Marshal.ReadInt32(path, offset + 8));     // 원본/대상 번호
      if (DisplayConfigGetDeviceInfo(p) != 0) { Marshal.FreeHGlobal(p); return IntPtr.Zero; }
      return p;
    }

    // 켜져 있는 화면마다 지금 해상도와 그 화면이 원하는 해상도(윈도우 '권장')를 알려 준다.
    public static List<MonitorMode> Monitors() {
      var list = new List<MonitorMode>();
      uint np, nm;
      if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0) return list;
      IntPtr paths = Marshal.AllocHGlobal((int)(np + 1) * 72);
      IntPtr modes = Marshal.AllocHGlobal((int)(nm + 1) * 64);
      try {
        if (QueryActive(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return list;
        var sources = new Dictionary<long, int>();
        for (int i = 0; i < np; i++) {
          IntPtr path = new IntPtr(paths.ToInt64() + i * 72);
          var m = new MonitorMode();
          IntPtr src = Packet(1, 84, path, 0);
          if (src != IntPtr.Zero) { m.Source = Marshal.PtrToStringUni(new IntPtr(src.ToInt64() + 20)); Marshal.FreeHGlobal(src); }
          IntPtr tgt = Packet(2, 420, path, 20);
          if (tgt != IntPtr.Zero) { m.Name = Marshal.PtrToStringUni(new IntPtr(tgt.ToInt64() + 36)); Marshal.FreeHGlobal(tgt); }
          IntPtr pref = Packet(3, 80, path, 20);
          if (pref != IntPtr.Zero) { m.BestWidth = Marshal.ReadInt32(pref, 20); m.BestHeight = Marshal.ReadInt32(pref, 24); Marshal.FreeHGlobal(pref); }
          var dm = new DevMode(); dm.dmSize = (short)Marshal.SizeOf(typeof(DevMode));
          if (m.Source != null && EnumDisplaySettings(m.Source, -1, ref dm)) { m.Width = dm.dmPelsWidth; m.Height = dm.dmPelsHeight; }
          long key = Marshal.ReadInt64(path, 0) ^ ((long)Marshal.ReadInt32(path, 8) << 40);
          int count; sources.TryGetValue(key, out count); sources[key] = count + 1;
          m.SourceKey = key;
          list.Add(m);
        }
        foreach (var m in list) m.Shared = sources[m.SourceKey] > 1;
      } finally { Marshal.FreeHGlobal(paths); Marshal.FreeHGlobal(modes); }
      return list;
    }

    // 0이면 성공. 바꾸기 전에 그 해상도를 받는지 먼저 시험해 본다.
    public static int SetResolution(string source, int width, int height) {
      var dm = new DevMode(); dm.dmSize = (short)Marshal.SizeOf(typeof(DevMode));
      if (!EnumDisplaySettings(source, -1, ref dm)) return -100;
      dm.dmPelsWidth = width; dm.dmPelsHeight = height;
      dm.dmFields = 0x80000 | 0x100000;
      int test = ChangeDisplaySettingsEx(source, ref dm, IntPtr.Zero, 0x2, IntPtr.Zero);
      if (test != 0) return test;
      return ChangeDisplaySettingsEx(source, ref dm, IntPtr.Zero, 0x1, IntPtr.Zero);
    }
  }

  public class MonitorMode {
    public string Name;        // 화면 이름 (모니터가 알려 주는 이름)
    public string Source;      // \\.\DISPLAY1 같은 윈도우 화면 번호
    public int Width, Height;            // 지금 해상도
    public int BestWidth, BestHeight;    // 화면이 원하는 해상도 (윈도우 '권장')
    public bool Shared;        // 다른 화면과 그림 하나를 나눠 씀 (복제)
    public long SourceKey;
  }

  public static class Touch {
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    // 0x80 준비됨, 0x01 내장 터치, 0x02 외장 터치(전자칠판), 0x04·0x08 펜
    public static int Digitizer() { return GetSystemMetrics(94); }
    public static int MaxTouches() { return GetSystemMetrics(95); }
  }

  // 창을 바탕화면 층에 붙인다. 바탕화면(Progman)을 주인 창으로 지정하면
  // 작업 표시줄에 안 뜨고, 다른 창 뒤에 깔리며, 바탕화면 보기(Win+D)에도 남는다.
  public static class Desk {
    [DllImport("user32.dll")] static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr64(IntPtr h, int index, IntPtr value);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr64(IntPtr h, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] static extern int SetWindowLong32(IntPtr h, int index, int value);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong32(IntPtr h, int index);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    static void SetLong(IntPtr h, int index, IntPtr value) {
      if (IntPtr.Size == 8) SetWindowLongPtr64(h, index, value); else SetWindowLong32(h, index, value.ToInt32());
    }
    static IntPtr GetLong(IntPtr h, int index) {
      return IntPtr.Size == 8 ? GetWindowLongPtr64(h, index) : new IntPtr(GetWindowLong32(h, index));
    }

    public static void Pin(IntPtr h) {
      SetLong(h, -8, FindWindow("Progman", null));                          // 주인 창 = 바탕화면
      SetLong(h, -20, new IntPtr(GetLong(h, -20).ToInt64() | 0x80));      // Alt+Tab 목록에서 숨김
      SendToBack(h);
    }

    public static void SendToBack(IntPtr h) {
      SetWindowPos(h, new IntPtr(1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10);        // 맨 아래, 크기·위치 유지, 활성화 안 함
    }
  }
}
'@
}
