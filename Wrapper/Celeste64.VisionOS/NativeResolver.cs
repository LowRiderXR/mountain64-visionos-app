using System.Reflection;
using System.Runtime.InteropServices;

namespace Celeste64.VisionOS;

/// <summary>
/// Resolves Foster's native import of SDL3 to the SDL3.framework the host app embeds.
/// .NET reports visionOS as iOS (<see cref="OperatingSystem.IsIOS"/> is true there), so the
/// iOS branch covers both. On every other platform the resolver stays out of the way and .NET's
/// default probing finds the library next to the executable, as it does on macOS.
///
/// Only one resolver may be registered per assembly. Foster registers none, so this one is
/// registered for Foster's assembly. Celeste 64 registers its own resolver for FMOD on its
/// assembly (Source/Audio/Audio.cs), which the visionOS patch extends with the same iOS branch
/// for FMOD.framework; registering a second one here would throw.
/// </summary>
internal static class NativeResolver
{
	private const string SdlFrameworkPath = "@rpath/SDL3.framework/SDL3";

	private static readonly object gate = new();
	private static bool registered;
	private static IntPtr sdlHandle;

	/// <summary>
	/// Registers the resolver once. Every export calls this first, so Foster's first P/Invoke
	/// finds the framework no matter which export the host uses first.
	/// </summary>
	public static void EnsureRegistered()
	{
		lock (gate)
		{
			if (registered)
				return;
			NativeLibrary.SetDllImportResolver(typeof(Foster.Framework.App).Assembly, Resolve);
			registered = true;
		}
	}

	private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
	{
		// macOS, Windows, Linux: default probing (libSDL3.dylib next to the executable).
		if (!OperatingSystem.IsIOS())
			return IntPtr.Zero;

		if (Path.GetFileNameWithoutExtension(libraryName) != "SDL3")
			return IntPtr.Zero;

		lock (gate)
		{
			if (sdlHandle == IntPtr.Zero && !NativeLibrary.TryLoad(SdlFrameworkPath, out sdlHandle))
				return IntPtr.Zero; // the runtime throws DllNotFoundException with the library name
			return sdlHandle;
		}
	}
}
