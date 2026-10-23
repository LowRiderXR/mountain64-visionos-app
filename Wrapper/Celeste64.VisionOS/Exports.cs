using System.Runtime.InteropServices;

namespace Celeste64.VisionOS;

/// <summary>
/// C entry points of the library. The host declares them in its bridging header:
///
///   const char *celeste_version(void);
///
/// Strings returned to the host stay valid for the lifetime of the process.
/// </summary>
public static class Exports
{
	private static IntPtr version;

	/// <summary>
	/// Game and runtime version, for example "Celeste 64 v.1.2.0, .NET 10.0.0". Also registers
	/// the native library resolver, so a host can call it first as a smoke test.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_version")]
	public static IntPtr CelesteVersion()
	{
		NativeResolver.EnsureRegistered();
		if (version == IntPtr.Zero)
			version = Marshal.StringToCoTaskMemUTF8($"Celeste 64 {Game.VersionString}, {RuntimeInformation.FrameworkDescription}");
		return version;
	}
}
