using System.Runtime.InteropServices;
using System.Text;
using Celeste64;
using Foster.Framework;
using static SDL3.SDL;

namespace Celeste64.VisionOS;

/// <summary>
/// Options of celeste_init; must match celeste_init_options in celeste.h field by field.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct CelesteInitOptions
{
	public int Size;
	public int HiddenWindow;
	public int DepthClip;
	public int Reserved;
	public IntPtr MetalDevice;
	public IntPtr MetalCommandQueue;
	public IntPtr CompletedCallback;
	public IntPtr CompletedUserdata;
	public IntPtr ContentRoot;
	// Added later; a host that passes the size of the struct up to ContentRoot gets the defaults.
	public int InternalWidth;
	public int InternalHeight;
	public int EdgeLineWidth;
	// 1: reverse-Z depth path (VR shader variants, infinite far plane), see celeste.h.
	public int ReverseZ;
}

/// <summary>
/// Frame data of celeste_render_frame_vr; must match celeste_vr_frame in celeste.h field by field.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public unsafe struct CelesteVRFrame
{
	public int Size;
	public int ViewCount;
	public IntPtr ColorTexture;
	public IntPtr DepthTexture;
	public int Width;
	public int Height;
	public int ColorSrgb;
	public int Reserved;
	public IntPtr RateMap;
	public int LogicalWidth;
	public int LogicalHeight;
	public int PhysicalWidth;
	public int PhysicalHeight;
	public fixed float Projection[32];
	public fixed float ViewTransform[32];
	public double NearMeters;
	public fixed float HeadTransform[16];
	public fixed float CullingProjection[16];
	public int OriginReset;
	public int Reserved2;
	public int DrewWorld;
	public int Flushes;
}

/// <summary>
/// Result of celeste_capabilities_get; must match celeste_capabilities in celeste.h.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct CelesteCapabilities
{
	public int Size;
	public int KitSdlLoaded;
	public int KitExports;
	public int MultiView;
	public int PassProperties;
	public int ExternalTextures;
	public int Memoryless;
	public int DepthResolve;
}

/// <summary>
/// Result of celeste_window_info_get; must match celeste_window_info in celeste.h.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct CelesteWindowInfo
{
	public int Size;
	public int Width;
	public int Height;
	public int PixelWidth;
	public int PixelHeight;
	public int PixelDensityX1000;
	public int Hidden;
	public int Fullscreen;
}

/// <summary>
/// C entry points of the library, declared for the host in celeste.h. Every entry point catches
/// all exceptions: an exception leaving an UnmanagedCallersOnly method would end the process, so
/// failures become -1 and a text in celeste_last_error. Only blittable parameters and returns.
/// </summary>
public static unsafe class Exports
{
	private const string Tag = "[celeste-visionos]";
	private const int Ok = 0;
	private const int Exiting = 1;
	private const int Failed = -1;

	private static IntPtr version;
	private static IntPtr lastError;
	private static Game? game;
	private static int initThreadId;
	private static long ticks;
	private static int lastTickThreadId;
	private static IntPtr initMetalDevice;
	private static readonly bool[] controllerConnected = new bool[InputState.MaxControllers];

	// Canvas: Foster texture over the host's MTLTexture and the target that the game's
	// output pass renders into (VisionOSKit.Outputs); null while the game renders to its window.
	private static Texture? canvasTexture;
	private static Target? canvasTarget;
	private static IntPtr canvasHandle;

	// Objective-C runtime, to read the MTLTexture's properties for the checks in celeste_set_canvas
	// (Foster and SDL know nothing about Metal objects; the kit checks the same values when it
	// wraps the texture, this gives the host a readable error before that).
	[DllImport("libobjc.A.dylib", EntryPoint = "sel_registerName")]
	private static extern IntPtr SelRegisterName([MarshalAs(UnmanagedType.LPStr)] string name);
	[DllImport("libobjc.A.dylib", EntryPoint = "objc_msgSend")]
	private static extern nuint ObjcMsgSendUInt(IntPtr receiver, IntPtr selector);
	[DllImport("libobjc.A.dylib", EntryPoint = "objc_msgSend")]
	private static extern IntPtr ObjcMsgSendPtr(IntPtr receiver, IntPtr selector);

	private static nuint TextureProperty(IntPtr texture, string selector) => ObjcMsgSendUInt(texture, SelRegisterName(selector));

	// Metal constants (MTLPixelFormat.h, MTLTexture.h, MTLResource.h)
	private const nuint MTLPixelFormatRGBA8Unorm = 70;
	private const nuint MTLTextureType2D = 2;
	private const nuint MTLTextureUsageShaderRead = 0x1;
	private const nuint MTLTextureUsageRenderTarget = 0x4;
	private const nuint MTLHazardTrackingModeTracked = 2;

	// Limits of the internal resolution and the outline width (celeste.h). Width a multiple of
	// 16 and height a multiple of 8: 16:9 steps such as 640x360 and 1920x1080 have heights that
	// are not multiples of 16.
	private const int MinInternalWidth = 640;
	private const int MinInternalHeight = 360;
	private const int MaxInternalWidth = 4096;
	private const int MaxInternalHeight = 2304;
	private const int InternalWidthStep = 16;
	private const int InternalHeightStep = 8;
	private const int MinEdgeLineWidth = 1;
	private const int MaxEdgeLineWidth = 4;

	/// <summary>
	/// Points the game's output pass at the host's texture: a Foster texture over the MTLTexture
	/// (external texture of the kit, RenderTarget | Sampled), a Target over it (color only, the
	/// game's output pass clears depth only where a depth attachment exists), and
	/// VisionOSKit.Outputs. SDL never cycles an external texture (SDL_gpu_metal.m,
	/// METAL_CreateTexture: canBeCycled = 0), so the host's texture receives every write.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_set_canvas")]
	public static int CelesteSetCanvas(IntPtr mtlTexture, int width, int height)
	{
		try
		{
			if (game == null)
				return SetError("celeste_set_canvas: no game; call celeste_init first");
			if (mtlTexture == IntPtr.Zero)
				return SetError("celeste_set_canvas: mtl_texture is null");
			if (width <= 0 || height <= 0 || width > 16384 || height > 16384)
				return SetError($"celeste_set_canvas: size {width}x{height} out of range");
			if (!game.GraphicsDevice.Capabilities.ExternalTextures)
				return SetError($"celeste_set_canvas: the loaded SDL has no external textures ({game.GraphicsDevice.Capabilities})");

			var textureWidth = TextureProperty(mtlTexture, "width");
			var textureHeight = TextureProperty(mtlTexture, "height");
			var pixelFormat = TextureProperty(mtlTexture, "pixelFormat");
			var textureType = TextureProperty(mtlTexture, "textureType");
			var usage = TextureProperty(mtlTexture, "usage");
			var sampleCount = TextureProperty(mtlTexture, "sampleCount");
			var arrayLength = TextureProperty(mtlTexture, "arrayLength");
			var mipLevels = TextureProperty(mtlTexture, "mipmapLevelCount");
			var hazardTracking = TextureProperty(mtlTexture, "hazardTrackingMode");
			var device = ObjcMsgSendPtr(mtlTexture, SelRegisterName("device"));
			var deviceMatches = initMetalDevice == IntPtr.Zero ? -1 : (device == initMetalDevice ? 1 : 0);
			Log.Info($"{Tag} canvas texture {textureWidth}x{textureHeight} pixelFormat={pixelFormat} type={textureType} usage=0x{usage:x} samples={sampleCount} layers={arrayLength} mips={mipLevels} hazardTracking={hazardTracking} device=0x{device:x} sameAsInit={deviceMatches}");

			if (textureWidth != (nuint)width || textureHeight != (nuint)height)
				return SetError($"celeste_set_canvas: texture is {textureWidth}x{textureHeight}, but {width}x{height} was given");
			if (pixelFormat != MTLPixelFormatRGBA8Unorm)
				return SetError($"celeste_set_canvas: pixel format {pixelFormat} is not RGBA8Unorm (70); Foster renders RGBA8, sample an sRGB view on the host side if needed");
			if (textureType != MTLTextureType2D)
				return SetError($"celeste_set_canvas: texture type {textureType} is not 2D (2)");
			if ((usage & (MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead)) != (MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead))
				return SetError($"celeste_set_canvas: usage 0x{usage:x} lacks RenderTarget (0x4) or ShaderRead (0x1)");
			if (sampleCount != 1 || arrayLength != 1 || mipLevels != 1)
				return SetError($"celeste_set_canvas: expected 1 sample, 1 layer, 1 mip level, got {sampleCount}, {arrayLength}, {mipLevels}");
			if (deviceMatches == 0)
				return SetError($"celeste_set_canvas: the texture's device 0x{device:x} is not the device given to celeste_init 0x{initMetalDevice:x}");
			if (hazardTracking != MTLHazardTrackingModeTracked)
				Log.Warning($"{Tag} canvas texture has hazardTrackingMode={hazardTracking}, not tracked (2): the host must order its reads itself");

			ReleaseCanvas();

			var properties = SDL_CreateProperties();
			SDL_SetPointerProperty(properties, SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER, mtlTexture);
			try
			{
				canvasTexture = new Texture(game.GraphicsDevice, width, height, TextureFormat.Color, 1, TextureFlags.RenderTarget | TextureFlags.Sampled, properties, "canvas");
			}
			finally
			{
				SDL_DestroyProperties(properties);
			}
			canvasTarget = new Target(game.GraphicsDevice, [canvasTexture], 0, "canvas");
			canvasHandle = mtlTexture;
			VisionOSKit.Outputs = [canvasTarget];
			Log.Info($"{Tag} canvas set {width}x{height}: the game's output pass renders into the host texture instead of the window");
			return Ok;
		}
		catch (Exception e)
		{
			ReleaseCanvas();
			return SetError(e);
		}
	}

	/// <summary>Back to the hidden window and release the game's reference to the texture.</summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_clear_canvas")]
	public static int CelesteClearCanvas()
	{
		try
		{
			if (game == null)
				return SetError("celeste_clear_canvas: no game");
			var had = canvasHandle;
			ReleaseCanvas();
			Log.Info($"{Tag} canvas cleared (was 0x{had:x}): the game's output pass renders into the window again");
			return Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	private static void ReleaseCanvas()
	{
		VisionOSKit.Outputs = null;
		canvasTarget?.Dispose();
		canvasTarget = null;
		canvasTexture?.Dispose();
		canvasTexture = null;
		canvasHandle = IntPtr.Zero;
	}

	/// <summary>
	/// Logs controller connections and disconnections as Foster's input sees them after a tick
	/// (gamepads are the input of the port; the keyboard is not probed). Single button presses
	/// are not logged: they filled the probe without telling anything new once the thread
	/// question was settled.
	/// </summary>
	private static void LogControllerChanges(Game game)
	{
		var controllers = game.Input.Controllers;
		var threadId = Environment.CurrentManagedThreadId;
		for (int i = 0; i < controllers.Length && i < controllerConnected.Length; i++)
		{
			var controller = controllers[i];
			if (controller.Connected != controllerConnected[i])
			{
				controllerConnected[i] = controller.Connected;
				Log.Info($"{Tag} controller index={i} connected={(controller.Connected ? 1 : 0)} name=\"{controller.Name}\" gamepad={(controller.IsGamepad ? 1 : 0)} type={controller.GamepadType} thread={threadId} tick={ticks}");
			}
		}
	}
	private static delegate* unmanaged<int, byte*, void*, void> logCallback;
	private static void* logUserdata;

	/// <summary>
	/// Routes Foster's log (which the game, Foster and SDL's forwarded messages all use) to the
	/// host: level 0 info, 1 warning, 2 error, text UTF-8 and NUL-terminated, valid only during
	/// the call. Call before celeste_init to catch the startup lines; a null callback restores
	/// Foster's default output. Foster may call the callback from any thread.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_set_log_callback")]
	public static int CelesteSetLogCallback(delegate* unmanaged<int, byte*, void*, void> callback, void* userdata)
	{
		try
		{
			logCallback = callback;
			logUserdata = userdata;
			if (callback == null)
				Log.SetCallbacks(null, null, null);
			else
				Log.SetCallbacks(text => ForwardLog(0, text), text => ForwardLog(1, text), text => ForwardLog(2, text));
			return Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	private static void ForwardLog(int level, ReadOnlySpan<char> text)
	{
		var callback = logCallback;
		if (callback == null)
			return;
		var count = Encoding.UTF8.GetByteCount(text);
		Span<byte> buffer = count < 1024 ? stackalloc byte[count + 1] : new byte[count + 1];
		var written = Encoding.UTF8.GetBytes(text, buffer);
		buffer[written] = 0;
		fixed (byte* utf8 = buffer)
			callback(level, utf8, logUserdata);
	}

	/// <summary>
	/// Game and runtime version, for example "Celeste 64 v.1.2.0, .NET 10.0.12". Also registers
	/// the native library resolver, so a host can call it first as a smoke test.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_version")]
	public static IntPtr CelesteVersion()
	{
		try
		{
			NativeResolver.EnsureRegistered();
			if (version == IntPtr.Zero)
				version = Marshal.StringToCoTaskMemUTF8($"Celeste 64 {Game.VersionString}, {RuntimeInformation.FrameworkDescription}");
			return version;
		}
		catch (Exception e)
		{
			SetError(e);
			return IntPtr.Zero;
		}
	}

	/// <summary>
	/// Capabilities of the loaded SDL: the kit probe by export name works before the game exists,
	/// the detailed flags come from the graphics device once celeste_init has run.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_capabilities_get")]
	public static int CelesteCapabilitiesGet(CelesteCapabilities* output)
	{
		try
		{
			if (output == null || output->Size != sizeof(CelesteCapabilities))
				return SetError($"celeste_capabilities: size must be {sizeof(CelesteCapabilities)}");
			NativeResolver.EnsureRegistered();
			var result = new CelesteCapabilities { Size = sizeof(CelesteCapabilities), KitSdlLoaded = GraphicsDevice.IsKitSDLLoaded() ? 1 : 0 };
			if (game != null)
			{
				var caps = game.GraphicsDevice.Capabilities;
				result.KitExports = caps.KitExports ? 1 : 0;
				result.MultiView = caps.MultiView ? 1 : 0;
				result.PassProperties = caps.PassProperties ? 1 : 0;
				result.ExternalTextures = caps.ExternalTextures ? 1 : 0;
				result.Memoryless = caps.Memoryless ? 1 : 0;
				result.DepthResolve = caps.DepthResolve ? 1 : 0;
			}
			*output = result;
			return Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	/// <summary>
	/// Creates the game and runs Celeste's Startup. Call on the main thread: SDL initializes
	/// its video subsystem here and creates the window (hidden if requested); the thread that
	/// does this is SDL's main thread from now on.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_init")]
	public static int CelesteInit(CelesteInitOptions* options)
	{
		uint properties = 0;
		try
		{
			if (game != null)
				return SetError("celeste_init: the game already exists; call celeste_end first");
			if (options == null)
				return SetError("celeste_init: options is null");
			// Two sizes are valid: the struct up to content_root (older hosts, defaults for the
			// rest) and the whole struct.
			var sizeWithoutResolution = (int)((byte*)&options->InternalWidth - (byte*)options);
			var hasResolution = options->Size == sizeof(CelesteInitOptions);
			if (!hasResolution && options->Size != sizeWithoutResolution)
				return SetError($"celeste_init: options.size must be {sizeWithoutResolution} or {sizeof(CelesteInitOptions)}");

			// Internal resolution and outline width: 0 means default; anything else is checked.
			var internalWidth = hasResolution && options->InternalWidth != 0 ? options->InternalWidth : MinInternalWidth;
			var internalHeight = hasResolution && options->InternalHeight != 0 ? options->InternalHeight : MinInternalHeight;
			var edgeLineWidth = hasResolution && options->EdgeLineWidth != 0 ? options->EdgeLineWidth : MinEdgeLineWidth;
			if (internalWidth < MinInternalWidth || internalHeight < MinInternalHeight)
				return SetError($"celeste_init: internal resolution {internalWidth}x{internalHeight} is below the minimum {MinInternalWidth}x{MinInternalHeight}");
			if (internalWidth > MaxInternalWidth || internalHeight > MaxInternalHeight)
				return SetError($"celeste_init: internal resolution {internalWidth}x{internalHeight} is above the maximum {MaxInternalWidth}x{MaxInternalHeight}");
			if (internalWidth % InternalWidthStep != 0 || internalHeight % InternalHeightStep != 0)
				return SetError($"celeste_init: internal resolution {internalWidth}x{internalHeight} must have a width that is a multiple of {InternalWidthStep} and a height that is a multiple of {InternalHeightStep}");
			if (edgeLineWidth < MinEdgeLineWidth || edgeLineWidth > MaxEdgeLineWidth)
				return SetError($"celeste_init: edge_line_width {edgeLineWidth} must be {MinEdgeLineWidth} to {MaxEdgeLineWidth}");

			var contentRoot = Marshal.PtrToStringUTF8(options->ContentRoot);
			if (string.IsNullOrEmpty(contentRoot))
				return SetError("celeste_init: content_root is required (the directory that contains Content/)");
			if (!Directory.Exists(Path.Join(contentRoot, "Content")))
				return SetError($"celeste_init: no Content directory in '{contentRoot}'");

			NativeResolver.EnsureRegistered();

			// Celeste looks for Content/ from AppContext.BaseDirectory upwards; point it at the
			// host's directory so the search hits at once and never leaves the app bundle.
			var baseDirectory = contentRoot.EndsWith(Path.DirectorySeparatorChar) ? contentRoot : contentRoot + Path.DirectorySeparatorChar;
			AppContext.SetData("APP_CONTEXT_BASE_DIRECTORY", baseDirectory);

			// SDL on iOS and visionOS insists on SDL_main unless told that main is handled by the host.
			SDL_SetMainReady();

			// Device properties for the SDL_GPU kit: host device and queue, completion callback.
			if (options->MetalDevice != IntPtr.Zero || options->MetalCommandQueue != IntPtr.Zero || options->CompletedCallback != IntPtr.Zero)
			{
				properties = SDL_CreateProperties();
				if (options->MetalDevice != IntPtr.Zero)
					SDL_SetPointerProperty(properties, SDL_PROP_GPU_DEVICE_CREATE_METAL_DEVICE_POINTER, options->MetalDevice);
				if (options->MetalCommandQueue != IntPtr.Zero)
					SDL_SetPointerProperty(properties, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_QUEUE_POINTER, options->MetalCommandQueue);
				if (options->CompletedCallback != IntPtr.Zero)
				{
					SDL_SetPointerProperty(properties, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_BUFFER_COMPLETED_CALLBACK_POINTER, options->CompletedCallback);
					SDL_SetPointerProperty(properties, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_BUFFER_COMPLETED_USERDATA_POINTER, options->CompletedUserdata);
				}
			}

			var flags = AppFlags.None;
			if (options->HiddenWindow != 0) flags |= AppFlags.HiddenWindow;
			if (options->DepthClip != 0) flags |= AppFlags.DepthClip;

			initThreadId = Environment.CurrentManagedThreadId;
			initMetalDevice = options->MetalDevice;
			ticks = 0;
			lastTickThreadId = 0;
			Array.Clear(controllerConnected);

			// The game reads its resolution from these when it creates its targets (Game.Width,
			// Game.Height, Game.RelativeScale) and the outline width in its edge pass.
			VisionOSKit.InternalWidth = internalWidth;
			VisionOSKit.InternalHeight = internalHeight;
			VisionOSKit.EdgeLineWidth = edgeLineWidth;
			// Depth convention: decided before the game exists (the world target is created with
			// the game, the shader variants are chosen when the assets load).
			var reverseZ = hasResolution && options->ReverseZ != 0;
			VisionOSKit.ReverseZ = reverseZ;
			Log.Info($"{Tag} init thread={initThreadId} contentRoot=\"{contentRoot}\" baseDirectory=\"{AppContext.BaseDirectory}\" hiddenWindow={options->HiddenWindow} depthClip={options->DepthClip} metalDevice=0x{options->MetalDevice:x} queue=0x{options->MetalCommandQueue:x} callback={(options->CompletedCallback != IntPtr.Zero ? 1 : 0)} internal={internalWidth}x{internalHeight} edgeLine={edgeLineWidth} reverseZ={(reverseZ ? 1 : 0)} worldScale={VisionOSKit.WorldScale:F1} optionsSize={options->Size}");

			var created = new Game(new(
				ApplicationName: Game.GamePath,
				WindowTitle: Game.GameTitle,
				Width: 1280,
				Height: 720,
				Fullscreen: false,
				Resizable: true,
				UpdateMode: UpdateMode.FixedStep(60),   // unused: the host owns the clock
				Flags: flags,
				GraphicsDeviceProperties: properties
			));
			if (properties != 0)
			{
				SDL_DestroyProperties(properties);
				properties = 0;
			}
			// Check against frozen values: everything derived from Game.RelativeScale is a static
			// readonly field, initialized when its class is first touched; this line touches them
			// after the game exists and shows what the game will draw with.
			Log.Info($"{Tag} derived width={Game.Width} height={Game.Height} relativeScale={Game.RelativeScale:F3} fontSize={Assets.FontSize} iconSize={UI.IconSize} promptSize={UI.PromptSize} menuSpacing={Menu.Spacing} cardWidth={Overworld.CardWidth} cardHeight={Overworld.CardHeight}");
			created.Begin();
			game = created;
			Log.Info($"{Tag} init ok userPath=\"{created.UserPath}\" window={created.Window.Width}x{created.Window.Height} pixels={created.Window.WidthInPixels}x{created.Window.HeightInPixels} internal={Game.Width}x{Game.Height} relativeScale={Game.RelativeScale:F3} edgeLine={VisionOSKit.EdgeLineWidth} capabilities={created.GraphicsDevice.Capabilities}");
			return Ok;
		}
		catch (Exception e)
		{
			if (properties != 0)
				SDL_DestroyProperties(properties);
			return SetError(e);
		}
	}

	/// <summary>
	/// One frame of the host clock. Returns 1 once the game asked to exit.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_tick")]
	public static int CelesteTick(double deltaSeconds, int present)
	{
		try
		{
			if (game == null)
				return SetError("celeste_tick: no game; call celeste_init first");
			// One line per thread that ticks: the first tick, and every change of the ticking
			// thread (the host moves from its main thread to the compositor's render thread).
			var threadId = Environment.CurrentManagedThreadId;
			if (threadId != lastTickThreadId)
			{
				lastTickThreadId = threadId;
				Log.Info($"{Tag} tick thread={threadId} name=\"{Thread.CurrentThread.Name}\" sameAsInit={(threadId == initThreadId ? 1 : 0)} sdlMainThread={(SDL_IsMainThread() ? 1 : 0)} delta={deltaSeconds * 1000:F3}ms present={present} tick={ticks}");
			}
			game.Tick(TimeSpan.FromSeconds(deltaSeconds), present != 0);
			ticks++;
			LogControllerChanges(game);
			return game.Exiting ? Exiting : Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	/// <summary>
	/// The update half of a frame (events, input, game logic) without rendering; the host calls
	/// it early in its frame, before the tracked pose is known. Returns 1 once the game asked to
	/// exit. celeste_render_frame completes the frame.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_update")]
	public static int CelesteUpdate(double deltaSeconds)
	{
		try
		{
			if (game == null)
				return SetError("celeste_update: no game; call celeste_init first");
			var threadId = Environment.CurrentManagedThreadId;
			if (threadId != lastTickThreadId)
			{
				lastTickThreadId = threadId;
				Log.Info($"{Tag} update thread={threadId} name=\"{Thread.CurrentThread.Name}\" sameAsInit={(threadId == initThreadId ? 1 : 0)} sdlMainThread={(SDL_IsMainThread() ? 1 : 0)} delta={deltaSeconds * 1000:F3}ms tick={ticks}");
			}
			game.Update(TimeSpan.FromSeconds(deltaSeconds));
			ticks++;
			LogControllerChanges(game);
			return game.Exiting ? Exiting : Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	/// <summary>
	/// The render half of a frame: renders the state of the last celeste_update and submits the
	/// GPU work (present 0) or presents to the window (present 1). The host calls it late in its
	/// frame, once the pose for this frame is known. 0 or -1.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_render_frame")]
	public static int CelesteRenderFrame(int present)
	{
		try
		{
			if (game == null)
				return SetError("celeste_render_frame: no game; call celeste_init first");
			game.RenderFrame(present != 0);
			return Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	/// <summary>
	/// The render half of a frame with the stereo world pass: imports the host's
	/// drawable (cached by identity), renders, and reports whether the world went into the
	/// drawable (1) or the canvas (0). See celeste_vr_frame in celeste.h.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_render_frame_vr")]
	public static int CelesteRenderFrameVR(CelesteVRFrame* frame)
	{
		try
		{
			if (game == null)
				return SetError("celeste_render_frame_vr: no game; call celeste_init first");
			if (frame == null || frame->Size != sizeof(CelesteVRFrame))
				return SetError($"celeste_render_frame_vr: frame.size must be {sizeof(CelesteVRFrame)}");
			if (!VisionOSKit.ReverseZ)
				return SetError("celeste_render_frame_vr: needs reverse_z = 1 at celeste_init");
			if (frame->ColorTexture == IntPtr.Zero || frame->DepthTexture == IntPtr.Zero)
				return SetError("celeste_render_frame_vr: color_texture and depth_texture are required");
			if (frame->ViewCount != 2)
				return SetError($"celeste_render_frame_vr: view_count must be 2, got {frame->ViewCount}");
			if (frame->Width <= 0 || frame->Height <= 0)
				return SetError($"celeste_render_frame_vr: texture size {frame->Width}x{frame->Height} is invalid");
			if (!game.GraphicsDevice.Capabilities.ExternalTextures || !game.GraphicsDevice.Capabilities.MultiView)
				return SetError($"celeste_render_frame_vr: the loaded SDL lacks external textures or multiview ({game.GraphicsDevice.Capabilities})");

			// once per new texture: does the native texture match what the game will request?
			if (!verifiedTextures.Contains(frame->ColorTexture))
			{
				var pixelFormat = TextureProperty(frame->ColorTexture, "pixelFormat");
				var expected = frame->ColorSrgb != 0 ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
				var arrayLength = TextureProperty(frame->ColorTexture, "arrayLength");
				var depthFormat = TextureProperty(frame->DepthTexture, "pixelFormat");
				var depthLayers = TextureProperty(frame->DepthTexture, "arrayLength");
				Log.Info($"{Tag} vr frame textures color=0x{frame->ColorTexture:x} format={pixelFormat} layers={arrayLength} depth=0x{frame->DepthTexture:x} format={depthFormat} layers={depthLayers} size={frame->Width}x{frame->Height} srgb={frame->ColorSrgb} map=0x{frame->RateMap:x} logical={frame->LogicalWidth}x{frame->LogicalHeight} physical={frame->PhysicalWidth}x{frame->PhysicalHeight}");
				if (pixelFormat != expected)
					return SetError($"celeste_render_frame_vr: colour pixel format {pixelFormat} is not {(frame->ColorSrgb != 0 ? "BGRA8Unorm_sRGB (81)" : "RGBA8Unorm (70)")}");
				if (depthFormat != MTLPixelFormatDepth32Float)
					return SetError($"celeste_render_frame_vr: depth pixel format {depthFormat} is not Depth32Float (252)");
				if (arrayLength != 2 || depthLayers != 2)
					return SetError($"celeste_render_frame_vr: textures must have 2 array layers, got {arrayLength} and {depthLayers}");
				verifiedTextures.Add(frame->ColorTexture);
			}

			if (frame->NearMeters > 0 && Math.Abs(frame->NearMeters - VisionOSKit.NearMeters) > 1e-6)
				VisionOSKit.SetNearMeters(frame->NearMeters);

			// 16 floats per view, the memory layout of simd_float4x4 (columns) equals the one of
			// System.Numerics.Matrix4x4 (rows) in the row-vector convention: copied without transpose
			float* p = frame->Projection;
			var projection0 = *(System.Numerics.Matrix4x4*)p;
			var projection1 = *(System.Numerics.Matrix4x4*)(p + 16);
			float* v = frame->ViewTransform;
			var eye0 = *(System.Numerics.Matrix4x4*)v;
			var eye1 = *(System.Numerics.Matrix4x4*)(v + 16);
			float* h = frame->HeadTransform;
			var head = *(System.Numerics.Matrix4x4*)h;
			float* c = frame->CullingProjection;
			var culling = *(System.Numerics.Matrix4x4*)c;
			// a host without a head pose (all zero) means identity: the game camera for both eyes
			if (head.M11 == 0 && head.M22 == 0 && head.M33 == 0 && head.M44 == 0)
			{
				head = System.Numerics.Matrix4x4.Identity;
				eye0 = System.Numerics.Matrix4x4.Identity;
				eye1 = System.Numerics.Matrix4x4.Identity;
			}
			if (culling.M11 == 0 && culling.M22 == 0)
				culling = VisionOSKit.UnionProjection(projection0, projection1);
			var entryTicks = System.Diagnostics.Stopwatch.GetTimestamp();
			VisionOSKit.RenderEntryTicks = entryTicks;
			VisionOSKit.BeginVRFrame(game.GraphicsDevice, frame->ColorTexture, frame->DepthTexture, frame->Width, frame->Height, frame->ViewCount,
				frame->ColorSrgb != 0, frame->RateMap, frame->LogicalWidth, frame->LogicalHeight, frame->PhysicalWidth, frame->PhysicalHeight,
				projection0, projection1, eye0, eye1, head, culling, frame->OriginReset != 0);
			bool rendered;
			int flushes;
			long worldCommitTicks;
			try
			{
				game.RenderFrame(false);
			}
			finally
			{
				worldCommitTicks = VisionOSKit.WorldCommitTicks;
				(rendered, flushes) = VisionOSKit.EndVRFrame();
			}
			frame->DrewWorld = rendered ? 1 : 0;
			frame->Flushes = flushes;
			// microseconds from the call to the commit of the world pass (0 without a world pass)
			frame->Reserved2 = worldCommitTicks > 0
				? (int)((worldCommitTicks - entryTicks) * 1_000_000 / System.Diagnostics.Stopwatch.Frequency)
				: 0;
			return rendered ? 1 : Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	private static readonly HashSet<IntPtr> verifiedTextures = [];
	private const nuint MTLPixelFormatBGRA8Unorm_sRGB = 81;
	private const nuint MTLPixelFormatDepth32Float = 252;

	/// <summary>
	/// Foster's window as SDL sees it: logical size, pixel size, density and flags. The host uses
	/// it to compare SDL's geometry request (logical size in points) with its own scene.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_window_info_get")]
	public static int CelesteWindowInfoGet(CelesteWindowInfo* output)
	{
		try
		{
			if (output == null || output->Size != sizeof(CelesteWindowInfo))
				return SetError($"celeste_window_info: size must be {sizeof(CelesteWindowInfo)}");
			if (game == null)
				return SetError("celeste_window_info: no game; call celeste_init first");
			// Foster keeps the SDL window handle internal; the game has exactly one window, so
			// SDL's own list gives the same handle (the MacHost does the same for its tests).
			var windows = SDL_GetWindows();
			if (windows.Length == 0)
				return SetError("celeste_window_info: SDL reports no window");
			var handle = windows[0];
			var flags = SDL_GetWindowFlags(handle);
			SDL_GetWindowSize(handle, out int width, out int height);
			SDL_GetWindowSizeInPixels(handle, out int pixelWidth, out int pixelHeight);
			*output = new CelesteWindowInfo
			{
				Size = sizeof(CelesteWindowInfo),
				Width = width,
				Height = height,
				PixelWidth = pixelWidth,
				PixelHeight = pixelHeight,
				PixelDensityX1000 = (int)MathF.Round(SDL_GetWindowPixelDensity(handle) * 1000),
				Hidden = (flags & SDL_WindowFlags.SDL_WINDOW_HIDDEN) != 0 ? 1 : 0,
				Fullscreen = (flags & SDL_WindowFlags.SDL_WINDOW_FULLSCREEN) != 0 ? 1 : 0,
			};
			return Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	[UnmanagedCallersOnly(EntryPoint = "celeste_exiting")]
	public static int CelesteExiting()
	{
		return game == null || game.Exiting ? 1 : 0;
	}

	/// <summary>
	/// Suspends (1) or resumes (0) FMOD's mixer for a backgrounded app (System::mixerSuspend and
	/// mixerResume; state and playback position are kept). Call both from the same thread with
	/// no celeste_tick in between, as FMOD requires.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_audio_suspend")]
	public static int CelesteAudioSuspend(int suspend)
	{
		try
		{
			if (game == null)
				return SetError("celeste_audio_suspend: no game");
			var result = VisionOSKit.SuspendAudio(suspend != 0);
			Log.Info($"{Tag} audio {(suspend != 0 ? "suspend" : "resume")} result={result} thread={Environment.CurrentManagedThreadId}");
			return result == FMOD.RESULT.OK ? Ok : SetError($"celeste_audio_suspend({suspend}): FMOD {result}");
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	/// <summary>
	/// Asks the game to pause at its next update (the device was put on again): a running level
	/// opens its pause menu, the title and the overworld do nothing. Any thread.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_request_pause")]
	public static int CelesteRequestPause()
	{
		try
		{
			if (game == null)
				return SetError("celeste_request_pause: no game");
			VisionOSKit.RequestPause();
			Log.Info($"{Tag} pause requested; the next update applies it to a running level");
			return Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	/// <summary>
	/// Near plane of the reverse-Z projection in metres; the host reads it from its layer's
	/// default depth range once the layer exists. The game converts it to world units at one
	/// place (VisionOSKit.SetNearMeters); the cameras pick it up with their next change. Call on
	/// the ticking thread. 0 or -1.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_set_depth_near")]
	public static int CelesteSetDepthNear(double nearMeters)
	{
		try
		{
			if (game == null)
				return SetError("celeste_set_depth_near: no game");
			if (!(nearMeters > 0) || double.IsInfinity(nearMeters))
				return SetError($"celeste_set_depth_near: {nearMeters} is not a positive finite distance in metres");
			VisionOSKit.SetNearMeters(nearMeters);
			Log.Info($"{Tag} depth near={nearMeters:F3} m -> {VisionOSKit.NearUnits:F2} units reverseZ={(VisionOSKit.ReverseZ ? 1 : 0)} thread={Environment.CurrentManagedThreadId}");
			return Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	/// <summary>
	/// Asks the game to exit as if the player chose Exit: Foster sets Exiting, the next
	/// celeste_tick returns 1. Lets a host exercise its own shutdown path without input.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_request_exit")]
	public static int CelesteRequestExit()
	{
		try
		{
			if (game == null)
				return SetError("celeste_request_exit: no game");
			game.Exit();
			Log.Info($"{Tag} exit requested by the host; the next tick returns 1 (exiting={(game.Exiting ? 1 : 0)})");
			return Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	/// <summary>
	/// Shuts the game down (Celeste's Shutdown, windows hidden, input closed) and disposes it,
	/// which quits SDL.
	/// </summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_end")]
	public static int CelesteEnd()
	{
		try
		{
			if (game == null)
				return SetError("celeste_end: no game");
			var ending = game;
			game = null;
			Log.Info($"{Tag} end ticks={ticks} frame={ending.Time.Frame} renderFrame={ending.Time.RenderFrame} thread={Environment.CurrentManagedThreadId} sameAsInit={(Environment.CurrentManagedThreadId == initThreadId ? 1 : 0)}");
			ReleaseCanvas();
			// End runs the game's Shutdown (scenes, Audio.Shutdown with FMOD's system.release) and
			// closes input; Dispose destroys the window and the GPU device and quits SDL. Both are
			// timed, so a host log shows where a slow shutdown spends its time.
			var stopwatch = System.Diagnostics.Stopwatch.StartNew();
			ending.End();
			var endMs = stopwatch.Elapsed.TotalMilliseconds;
			stopwatch.Restart();
			ending.Dispose();
			Log.Info($"{Tag} end: End() ms={endMs:F1} Dispose() ms={stopwatch.Elapsed.TotalMilliseconds:F1}");
			return Ok;
		}
		catch (Exception e)
		{
			return SetError(e);
		}
	}

	/// <summary>Text of the last failure, empty if none.</summary>
	[UnmanagedCallersOnly(EntryPoint = "celeste_last_error")]
	public static IntPtr CelesteLastError()
	{
		if (lastError == IntPtr.Zero)
			lastError = Marshal.StringToCoTaskMemUTF8(string.Empty);
		return lastError;
	}

	private static int SetError(Exception e) => SetError(e.ToString());

	private static int SetError(string message)
	{
		Log.Error($"{Tag} {message}");
		var previous = lastError;
		lastError = Marshal.StringToCoTaskMemUTF8(message);
		if (previous != IntPtr.Zero)
			Marshal.FreeCoTaskMem(previous);
		return Failed;
	}
}
