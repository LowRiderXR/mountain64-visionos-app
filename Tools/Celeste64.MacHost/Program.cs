// Celeste64.MacHost — drives Celeste 64 from the outside and renders into output targets of the
// host. Model for the Swift host on visionOS: create the Game, Begin(), then Tick(delta) per
// frame of the host's own clock, End().
//
//   --hz N              rate and delta (90, 100, 120; default 90), delta = 1/N s
//   --jitter-ms J       sleep randomly up to J ms before every tick (an uneven wall clock like on
//                       the headset); the delta stays the grid 1/N, fosterDelta constant
//   --seconds S         run time (default 30); 0 = until Escape in the game
//   --gap-ms M          one gap of M ms after 5 s (pause, no catching up)
//   --no-present        window hidden, tick without present (commands are still submitted)
//   --gpu-timing        set the kit's completion callback (C64_GPU_TIMING=1), count the callbacks
//   --layers none|foster|external
//                       render the final image into a target with two layers instead of the
//                       window, one pass per layer. foster = Foster creates the 2D array texture;
//                       external = an existing MTLTexture (type2DArray) from the native helper
//                       libk6dmetal.dylib, imported through the SDL texture property, device and
//                       queue of the host through the device properties. Both layers are shown
//                       side by side in the window.
//   --layer-check N     every N ticks read both layers back and compare them (default 300)
//   --no-layer-depth    without a depth array (default: colour and depth with two layers each)
//   --layer-selftest    once try the forbidden 2D operations on the array (download, blit and
//                       sampling without a layer) and log the exceptions
//   --windowed          lift the fullscreen from the save game again (test in the window)
//   --tap-confirm T,T   at these ticks press the confirm key (C) briefly (SDL_PushEvent), for
//                       example 120,240,360 for title, overworld, level 1
//   --target-check N    every N ticks read Celeste's 640x360 world target back (colour and depth):
//                       magenta, non-black, depth statistics
//   --target-dump PFX   also write the colour as PFX-<frame>.ppm (comparison MSAA on/off)
//   --blit-selftest     two blits side by side into the same texture, read back, both halves
//                       must stand (blit into a sub-rectangle)
//   --msaa N            the layer targets with N samples; Foster creates the MSAA textures and
//                       resolves into the existing layers (colour through resolve_texture, depth
//                       through the kit properties)
//   --memoryless M      none | color | color+depth: MSAA colour (and depth) only in tile memory
//   --no-multisample-store
//                       do not keep the colour samples after the pass (RESOLVE only); required for
//                       memoryless colour. Default is to keep them: a forgotten setting costs
//                       performance, not the image. memoryless colour without this switch is the
//                       negative test (rejected)
//   --depth-format F    d16 | d32 (default d32, like the headset's drawable depth)
//   --views N           1 = one pass per layer (two targets), 2 = one pass onto both layers (one
//                       target with Target.ViewCount 2, vertex amplification)
//   --test-quad         the host draws a black field with a slanted green quad in the same pass;
//                       the layer comparison counts edge pixels with intermediate values there
//   --rate-map          the host's own two-layer rate map (same profile in all layers and axes,
//                       1.0 in the first third, 0.5 after that) set on the target every frame
//                       (Target.SetRasterizationRateMap); viewport, scissor and batcher then work
//                       in the logical space of the map. Only with --layers external (host device).
//                       Measurement image in every (layer-check/2)-th tick: black image with bars
//                       at known logical positions, read both layers back, expected values from
//                       mapScreenToPhysicalCoordinates, tolerance 1 px
//   --rate-map-scale F  logical size of the map = F x texture size (default 1.4; physical about
//                       0.67 x logical, fits into 1280x720). 2.0 is the negative test: physically
//                       larger than the texture, SDL rejects the pass, Foster throws
//   --pass-selftest     device in debug mode (SDL_ASSERT=ignore), an ordinary pass that SDL
//                       rejects (depth texture with 256 layers) must give an exception with a
//                       message; counter-check with a valid target
//   --minimize-at T,T   minimize the window at the first tick, restore it at the second; the run
//                       must continue without an exception
//   --tap-pause T,T     at these ticks press the pause key (Escape) briefly (SDL_PushEvent)
//   --tap-down T,T      at these ticks press the menu key Down briefly
//   --layer-dump-ticks T,T  additionally at these ticks a layer comparison and dump
//   --hold-key K:T0:T1  hold key K from tick T0 to T1: left right up down (movement), w a s d
//                       (camera), c (jump), x (dash), z (climb)
//   --gamepad-sim T0:T1 simulated gamepad (VisionOSKit.GamepadPrompt.SimulatedConnected): connected
//                       from the start, lost from tick T0 to T1; without the option the real state
//                       counts (the Mac without a gamepad shows the line "Connect a game controller to play")
//   --key-probe N       inject an F7 key event before tick N (SDL_PushEvent), release it two
//                       ticks later; reports after which tick Foster sees the key as pressed and
//                       as released (before da3b23a N+1, afterwards N)
//   --vr-depth          reverse-Z path (VisionOSKit.ReverseZ, near 0.1 m like the headset's
//                       layer): shader variants without SV_Depth, world target Depth32, clear 0,
//                       compares swapped, sky 3 km
//   --test-projection   additionally the test projection shaped like computeProjection (Metal RH,
//                       infinite far plane, tangents left 1.732, right 1.0, top 1.0, bottom 1.192)
//   --vr-world          stereo world pass. Before every tick Celeste gets the external layers as
//                       its "drawable" (VisionOSKit.BeginVRFrame: colour and depth as 2D array,
//                       the host's rate map if --rate-map, test projection per eye: eye 0 tangents
//                       1.732/1.0/1.0/1.192, eye 1 mirrored), a level writes its world straight
//                       into it; title and overworld keep running through Outputs. Needs --layers
//                       external --views 2; implies --vr-depth. The layer comparison then no
//                       longer requires equal layers
//   --res WxH           internal resolution (VisionOSKit.InternalWidth/Height) and outline width auto
//   --layer-dump PFX    at every layer comparison write both layers (physical region) as
//                       PFX-L0-<frame>.rgba and PFX-L1-<frame>.rgba
//   --vr-check          at every layer comparison in the world pass check drawable layer 0 against
//                       the world target A (VisionOSKit.Intermediate): only outline pixels may
//                       differ; measure the outline width as the most frequent run length of
//                       horizontal outline runs in the image centre and at the border against the
//                       expectation angle·(1+x²+y²)·k/rate in physical pixels; with
//                       C64_STEREO_NEGATIVE=no-angle and --rate-map the border must deviate. It
//                       also reads the depth of A and counts outline pixels by zones (near z < 5 m,
//                       far z > 15 m) and on flat pixels (Laplacian of the raw depth below a tenth
//                       of the threshold): 0 on flat surfaces
//   --pixel-msaa N      pixel look: 0 or 4 samples in the world pass into A (memoryless, resolved
//                       only, depth with max; VisionOSKit.PixelMsaa, default 4)
//   --edge-deg D        outline width in degrees (VisionOSKit.EdgeAngleDegrees, default 0.12)
//   --coarse-dump PFX   in the vr-check write the resolved colour of A, layer 0, as
//                       PFX-A-L0-<frame>.rgba (MSAA edges: compare a run with 4 against a run
//                       with 0, the share of differing pixels must be > 0; two runs with 0 must
//                       be identical)
//   --stereo-selftest   arithmetic check without an image (VisionOSKit.DebugProject): game camera
//                       at the origin looking +Y, eyes ±0.032 m, symmetric projection (tangents 1),
//                       1000 px: a point at 2 m gives a disparity of 16 px (±10 %), axis marks
//                       ahead (centred), right (x ≈ 750) and up (y ≈ 250); the left eye sees the
//                       point right of the centre
//   --layer-size WxH    size of the external layers (default 1280x720; 2624x2560 like the drawable
//                       of the M5 at quality 1.0)
//   --gpu-passes        performance: own completion callback; GPU start and end per command
//                       buffer, per second the inclusive and exclusive time per pass (world, edge,
//                       sprites, rest, canvas) and the sum per world frame
//   --metal-capture PATH:TICK
//                       Metal capture of tick TICK as .gputrace to PATH (the process needs
//                       METAL_CAPTURE_ENABLED=1), open in Xcode
//   --depth-check N     every N ticks draw three test quads at 1, 5 and 30 m in front of the camera
//                       (in view space) into the world target, read the depth back: near/d must
//                       hit the distance to 1 %; also the smallest depth of the image (sky: > 0, in
//                       the dome range) and the number of pixels at the clear value 0; the sky is
//                       only judged in the level (after the last --tap-confirm key plus 300
//                       ticks), frames of a wipe are skipped
//
// Preview: the window is cleared to black first in every frame; each layer is blitted into its
// own 2D texture (one blit covers its target completely, because Foster's blit is a pass with
// DONT_CARE and cycle over the whole target texture) and both textures are drawn side by side in
// one batcher pass. The layer comparison additionally builds the same composition into an
// offscreen target of window size and reads it back: no magenta, halves equal, borders black.
//
// One line per second: ticks, updates, updates per tick, delta (requested and reported by
// Foster), callbacks.

using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Celeste64;
using Foster.Framework;
using static SDL3.SDL;
using Matrix = System.Numerics.Matrix4x4;
using Vec2 = System.Numerics.Vector2;
using Vec3 = System.Numerics.Vector3;
using Vec4 = System.Numerics.Vector4;

int hz = 90;
double jitterMs = 0;
var jitterRng = new Random(12345);
double seconds = 30;
double gapMs = 0;
bool noPresent = false;
bool gpuTiming = false;
string layers = "none";
int layerCheck = 300;
bool layerDepth = true;
bool layerSelftest = false;
bool windowed = false;
var tapConfirm = new List<long>();
int targetCheck = 0;
string? targetDump = null;
bool blitSelftest = false;
int hostMsaa = 1;
string memoryless = "none";
bool multiSampleStore = true;
string depthFormat = "d32";
bool testQuad = false;
int views = 1;
bool rateMap = false;
float rateMapScale = 1.4f;
bool passSelftest = false;
var minimizeAt = new List<long>();
long keyProbeAt = -1;
var tapPause = new List<long>();     // Escape (pause) at these ticks, released two ticks later
var tapDown = new List<long>();      // menu Down key at these ticks
(long from, long to)? gamepadSim = null; // simulated gamepad: connected from the start, lost between these ticks
var layerDumpTicks = new List<long>(); // additional layer dumps at these ticks
var holdKeys = new List<(SDL_Scancode key, long from, long to)>(); // hold a movement key between two ticks
long keyProbeSeenDown = -1, keyProbeSeenUp = -1;
// reverse-Z path, test projection, depth check
bool vrDepth = false, testProjection = false;
int depthCheck = 0;
// stereo world pass, internal resolution, layer dumps, comparison drawable against A
bool vrWorld = false, vrCheck = false, stereoSelftest = false;
int pixelMsaa = -1;
string? coarseDump = null;
float edgeDeg = 0;
bool gpuPasses = false;
string? metalCapturePath = null; long metalCaptureTick = -1;
int layerSizeW = 1280, layerSizeH = 720;
const float StereoIpd = 0.064f;
int resW = 0, resH = 0;
string? layerDump = null;
long vrWorldFrames = 0, vrCanvasFrames = 0;
int vrChecks = 0, vrChecksFailed = 0;
bool depthCheckThisFrame = false, sceneRenderedThisFrame = false;
int depthChecks = 0, depthChecksFailed = 0;
long afterOutputCalls = 0;
// the host's map, its logical and physical size, measurement frame
nint rateMapPtr = 0;
int logicalW = 0, logicalH = 0;
uint physW = 0, physH = 0;
bool measureThisFrame = false;

for (int i = 0; i < args.Length; i++)
{
	switch (args[i])
	{
		case "--hz": hz = int.Parse(args[++i]); break;
		case "--jitter-ms": jitterMs = double.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture); break;
		case "--seconds": seconds = double.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture); break;
		case "--gap-ms": gapMs = double.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture); break;
		case "--no-present": noPresent = true; break;
		case "--gpu-timing": gpuTiming = true; break;
		case "--layers": layers = args[++i]; break;
		case "--layer-check": layerCheck = int.Parse(args[++i]); break;
		case "--no-layer-depth": layerDepth = false; break;
		case "--layer-selftest": layerSelftest = true; break;
		case "--windowed": windowed = true; break;
		case "--tap-confirm": foreach (var t in args[++i].Split(',')) tapConfirm.Add(long.Parse(t)); break;
		case "--target-check": targetCheck = int.Parse(args[++i]); break;
		case "--target-dump": targetDump = args[++i]; break;
		case "--blit-selftest": blitSelftest = true; break;
		case "--msaa": hostMsaa = int.Parse(args[++i]); break;
		case "--memoryless": memoryless = args[++i]; break;
		case "--no-multisample-store": multiSampleStore = false; break;
		case "--depth-format": depthFormat = args[++i]; break;
		case "--test-quad": testQuad = true; break;
		case "--views": views = int.Parse(args[++i]); break;
		case "--rate-map": rateMap = true; break;
		case "--rate-map-scale": rateMapScale = float.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture); break;
		case "--pass-selftest": passSelftest = true; break;
		case "--minimize-at": foreach (var t in args[++i].Split(',')) minimizeAt.Add(long.Parse(t)); break;
		case "--key-probe": keyProbeAt = long.Parse(args[++i]); break;
		case "--tap-pause": foreach (var t in args[++i].Split(',')) tapPause.Add(long.Parse(t)); break;
		case "--tap-down": foreach (var t in args[++i].Split(',')) tapDown.Add(long.Parse(t)); break;
		case "--layer-dump-ticks": foreach (var t in args[++i].Split(',')) layerDumpTicks.Add(long.Parse(t)); break;
		case "--hold-key":
		{
			// NAME:FROM:TO, NAME one of w a s d (camera with the keyboard-camera filter), left right up
			// down (movement), c (jump), x (dash), z (climb)
			var parts = args[++i].Split(':');
			var key = parts[0] switch
			{
				"w" => SDL_Scancode.SDL_SCANCODE_W, "a" => SDL_Scancode.SDL_SCANCODE_A, "s" => SDL_Scancode.SDL_SCANCODE_S, "d" => SDL_Scancode.SDL_SCANCODE_D,
				"left" => SDL_Scancode.SDL_SCANCODE_LEFT, "right" => SDL_Scancode.SDL_SCANCODE_RIGHT, "up" => SDL_Scancode.SDL_SCANCODE_UP, "down" => SDL_Scancode.SDL_SCANCODE_DOWN,
				"x" => SDL_Scancode.SDL_SCANCODE_X, "z" => SDL_Scancode.SDL_SCANCODE_Z, _ => SDL_Scancode.SDL_SCANCODE_C,
			};
			holdKeys.Add((key, long.Parse(parts[1]), long.Parse(parts[2])));
			break;
		}
		case "--gamepad-sim":
		{
			var parts = args[++i].Split(':');
			gamepadSim = (long.Parse(parts[0]), long.Parse(parts[1]));
			break;
		}
		case "--vr-depth": vrDepth = true; break;
		case "--test-projection": testProjection = true; break;
		case "--depth-check": depthCheck = int.Parse(args[++i]); break;
		case "--vr-world": vrWorld = true; vrDepth = true; break;
		case "--vr-check": vrCheck = true; break;
		case "--pixel-msaa": pixelMsaa = int.Parse(args[++i]); break;
		case "--coarse-dump": coarseDump = args[++i]; break;
		case "--edge-deg": edgeDeg = float.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture); break;
		case "--stereo-selftest": stereoSelftest = true; break;
		case "--gpu-passes": gpuPasses = true; break;
		case "--layer-size":
		{
			var parts = args[++i].Split('x');
			layerSizeW = int.Parse(parts[0]); layerSizeH = int.Parse(parts[1]);
			break;
		}
		case "--metal-capture":
		{
			var parts = args[++i].Split(':');
			metalCapturePath = parts[0]; metalCaptureTick = long.Parse(parts[1]);
			break;
		}
		case "--res":
		{
			var parts = args[++i].Split('x');
			resW = int.Parse(parts[0]); resH = int.Parse(parts[1]);
			break;
		}
		case "--layer-dump": layerDump = args[++i]; break;
		default: Console.Error.WriteLine($"Unknown argument: {args[i]}"); return 64;
	}
}
if (testProjection && !vrDepth)
{
	Console.Error.WriteLine("--test-projection requires --vr-depth (the projection only applies on the reverse-Z path)");
	return 64;
}
if (vrWorld && (layers != "external" || views != 2))
{
	Console.Error.WriteLine("--vr-world requires --layers external --views 2");
	return 64;
}
if (pixelMsaa >= 0)
	VisionOSKit.PixelMsaa = pixelMsaa;
if (edgeDeg > 0)
	VisionOSKit.EdgeAngleDegrees = edgeDeg;
if (resW > 0 && resH > 0)
{
	VisionOSKit.InternalWidth = resW;
	VisionOSKit.InternalHeight = resH;
	VisionOSKit.EdgeLineWidth = Math.Max(1, (int)MathF.Round(resH / 360f));
}
if (vrDepth)
{
	// before the game: world target and shader selection read the switch when created or loaded
	VisionOSKit.ReverseZ = true;
	VisionOSKit.SetNearMeters(0.1);
	if (testProjection)
		VisionOSKit.ProjectionOverride = VisionOSKit.CreateProjectionFromTangents(1.732f, 1.0f, 1.0f, 1.192f);
}
if (layers is not ("none" or "foster" or "external"))
{
	Console.Error.WriteLine($"--layers expects none, foster or external, not '{layers}'");
	return 64;
}

Thread.CurrentThread.CurrentCulture = System.Globalization.CultureInfo.InvariantCulture;
if (gpuTiming)
	Environment.SetEnvironmentVariable("C64_GPU_TIMING", "1");

Log.Info($"[machost] hz={hz} seconds={seconds} gapMs={gapMs} present={!noPresent} gpuTiming={gpuTiming} layers={layers} layerDepth={layerDepth} kitSDL={GraphicsDevice.IsKitSDLLoaded()} vrDepth={vrDepth} testProjection={testProjection} depthCheck={depthCheck}");

// Device properties: completion callback and, for the external path, device and queue of
// the host, as the layer renderer provides them on the headset.
var kitProperties = VisionOSKit.CreateDeviceProperties();
nint hostDevice = 0, hostQueue = 0;
if (layers == "external")
{
	hostDevice = K6dMetal.k6d_metal_device();
	hostQueue = K6dMetal.k6d_metal_queue(hostDevice);
	if (hostDevice == 0 || hostQueue == 0)
	{
		Log.Error("[machost] host Metal device or queue missing");
		return 1;
	}
	if (kitProperties == 0)
		kitProperties = SDL_CreateProperties();
	SDL_SetPointerProperty(kitProperties, SDL_PROP_GPU_DEVICE_CREATE_METAL_DEVICE_POINTER, hostDevice);
	SDL_SetPointerProperty(kitProperties, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_QUEUE_POINTER, hostQueue);
	Log.Info($"[machost] host device 0x{hostDevice:x} and queue 0x{hostQueue:x} set as import properties");
}
unsafe
{
	if (gpuPasses)
	{
		// performance: own callback instead of the counter from VisionOSKit (overrides it)
		if (kitProperties == 0)
			kitProperties = SDL_CreateProperties();
		delegate* unmanaged[Cdecl]<nint, nint, void> cb = &GpuPassTimer.OnCompleted;
		SDL_SetPointerProperty(kitProperties, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_BUFFER_COMPLETED_CALLBACK_POINTER, (nint)cb);
		SDL_SetPointerProperty(kitProperties, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_BUFFER_COMPLETED_USERDATA_POINTER, nint.Zero);
		Log.Info("[machost] gpu passes: completion callback set (GPUStartTime/GPUEndTime per command buffer)");
	}
}

var flags = VisionOSKit.Flags | (noPresent ? AppFlags.HiddenWindow : AppFlags.None);
if (passSelftest)
{
	// SDL's debug checks at the start of a pass report through SDL_assert_release and return
	// NULL; without this hint SDL shows a dialog and the run hangs. The hint has to be set through
	// SDL_SetHint: Environment.SetEnvironmentVariable does not reach the native environment under
	// .NET on macOS (the first attempt hung in the dialog). Turn on the device's debug mode.
	SDL_SetHint("SDL_ASSERT", "ignore");
	flags |= AppFlags.GraphicsDebugging;
}
using var game = new Game(new(
	ApplicationName: Game.GamePath,
	WindowTitle: Game.GameTitle,
	Width: 1280,
	Height: 720,
	Fullscreen: false,
	Resizable: true,
	UpdateMode: UpdateMode.FixedStep(60),   // unused in host mode, the host owns the clock
	Flags: flags,
	GraphicsDeviceProperties: kitProperties
));
if (kitProperties != 0)
	SDL_DestroyProperties(kitProperties);

if (stereoSelftest)
{
	// check the conversion head pose -> Celeste without an image
	var cam = Vec3.Zero; var look = new Vec3(0, 1, 0);
	var proj = VisionOSKit.CreateProjectionFromTangents(1f, 1f, 1f, 1f);
	var left = Matrix.CreateTranslation(-StereoIpd / 2, 0, 0);
	var right = Matrix.CreateTranslation(StereoIpd / 2, 0, 0);
	const int W = 1000, H = 1000;
	var s = VisionOSKit.WorldScale;
	var pFront = new Vec3(0, 2 * s, 0); var pRight = new Vec3(1 * s, 2 * s, 0); var pUp = new Vec3(0, 2 * s, 1 * s);
	var fl = VisionOSKit.DebugProject(cam, look, left, proj, pFront, W, H);
	var fr = VisionOSKit.DebugProject(cam, look, right, proj, pFront, W, H);
	var disparity = fl.X - fr.X;
	var expected = (W / 2f) * (StereoIpd / 2f);   // f = W / (l + r) = 500 px per tangent unit, tangent IPD / distance
	var okDisp = Math.Abs(disparity - expected) <= expected * 0.10f && fl.X > W / 2f;
	var rl = VisionOSKit.DebugProject(cam, look, left, proj, pRight, W, H);
	var ul = VisionOSKit.DebugProject(cam, look, left, proj, pUp, W, H);
	var okAxes = Math.Abs(fl.Y - H / 2f) < 1 && Math.Abs(fl.X - (W / 2f + expected / 2f)) < 1
		&& Math.Abs(rl.X - (W / 2f + W / 4f + expected / 2f)) < 1 && Math.Abs(rl.Y - H / 2f) < 1
		&& Math.Abs(ul.Y - (H / 2f - H / 4f)) < 1 && Math.Abs(ul.X - fl.X) < 1;
	Log.Info($"[machost] stereo selftest: point 2 m ahead left=({fl.X:F1},{fl.Y:F1}) right=({fr.X:F1},{fr.Y:F1}) disparity={disparity:F2} px expected={expected:F2} ({(okDisp ? "ok" : "ERROR")}); axes: right mark left-eye=({rl.X:F1},{rl.Y:F1}) up mark=({ul.X:F1},{ul.Y:F1}) ({(okAxes ? "ok" : "ERROR")}); scale={s}");
	// with a yawed game camera (looking +X) the forward mark must stay centred
	var fy = VisionOSKit.DebugProject(cam, new Vec3(1, 0, 0), Matrix.Identity, proj, new Vec3(2 * s, 0, 0), W, H);
	var fyUp = VisionOSKit.DebugProject(cam, new Vec3(1, 0, 0), Matrix.Identity, proj, new Vec3(2 * s, 0, 1 * s), W, H);
	var okYaw = Math.Abs(fy.X - W / 2f) < 1 && Math.Abs(fy.Y - H / 2f) < 1 && Math.Abs(fyUp.Y - (H / 2f - H / 4f)) < 1;
	Log.Info($"[machost] stereo selftest: yawed camera (+X) forward=({fy.X:F1},{fy.Y:F1}) up=({fyUp.X:F1},{fyUp.Y:F1}) ({(okYaw ? "ok" : "ERROR")})");
	if (!(okDisp && okAxes && okYaw)) return 2;
}

var delta = TimeSpan.FromSeconds(1.0 / hz);
game.Begin();
Log.Info($"[machost] Begin done, window {(noPresent ? "hidden" : "visible")}, start time {game.Time.Elapsed.TotalMilliseconds:F1} ms, capabilities {game.GraphicsDevice.Capabilities}");

// An ordinary pass that SDL rejects must give an exception with a message instead of dropping
// the draws silently. Simplest reachable case: SDL's debug check "Cannot bind a depth texture
// with more than 255 layers!" (depth texture with 256 layers, 4x4). Counter-check: a valid
// small target without an exception.
if (passSelftest)
{
	var gd = game.GraphicsDevice;
	Texture? bigColor = null, bigDepth = null; Target? bad = null;
	try
	{
		bigColor = new Texture(gd, 4, 4, TextureFormat.Color, 256, TextureFlags.RenderTarget, 0, "k6f-color-256");
		bigDepth = new Texture(gd, 4, 4, TextureFormat.Depth32, 256, TextureFlags.RenderTarget, 0, "k6f-depth-256");
		bad = new Target(gd, [bigColor, bigDepth], 0, name: "k6f-bad-pass");
		bad.Clear(Color.Black, 1, 0, ClearMask.Color | ClearMask.Depth);
		Log.Error("[machost] pass selftest 'depth with 256 layers': NO exception (draws silently dropped)");
	}
	catch (InvalidOperationException e)
	{
		Log.Info($"[machost] pass selftest 'depth with 256 layers': rejected ({e.GetType().Name}: {e.Message})");
	}
	catch (Exception e)
	{
		Log.Error($"[machost] pass selftest 'depth with 256 layers': unexpected {e.GetType().Name}: {e.Message}");
	}
	finally
	{
		bad?.Dispose(); bigColor?.Dispose(); bigDepth?.Dispose();
	}
	try
	{
		using var good = new Target(gd, 8, 8, "k6f-good-pass");
		good.Clear(Color.Black);
		Log.Info("[machost] pass selftest 'valid target 8x8': ok (no exception)");
	}
	catch (Exception e)
	{
		Log.Error($"[machost] pass selftest 'valid target 8x8': ERROR {e.GetType().Name}: {e.Message}");
	}
}

// ---- Output target with two layers ----
int LayerW = layerSizeW, LayerH = layerSizeH;
const int LayerCount = 2;
Texture? layerColor = null, layerDepthTex = null, previewLeft = null, previewRight = null;
Target? composeCheck = null;
Target? layer0 = null, layer1 = null;
Batcher? batcher = null;
nint mtlColor = 0, mtlDepth = 0;
uint extColorProps = 0, extDepthProps = 0;
if (layers != "none")
{
	var gd = game.GraphicsDevice;
	try
	{
		if (layers == "foster")
		{
			layerColor = new Texture(gd, LayerW, LayerH, TextureFormat.Color, LayerCount, TextureFlags.RenderTarget, 0, "k6d-color");
			if (layerDepth)
				layerDepthTex = new Texture(gd, LayerW, LayerH, depthFormat == "d16" ? TextureFormat.Depth16 : TextureFormat.Depth32, LayerCount, TextureFlags.RenderTarget, 0, "k6d-depth");
		}
		else
		{
			// existing MTLTexture of the host: colour readable (for the preview blits), depth target only
			mtlColor = K6dMetal.k6d_metal_array_texture(hostDevice, (uint)LayerW, (uint)LayerH, LayerCount, 0);
			extColorProps = SDL_CreateProperties();
			SDL_SetPointerProperty(extColorProps, SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER, mtlColor);
			layerColor = new Texture(gd, LayerW, LayerH, TextureFormat.Color, LayerCount, TextureFlags.RenderTarget | TextureFlags.Sampled, extColorProps, "k6d-ext-color");
			if (layerDepth)
			{
				mtlDepth = K6dMetal.k6d_metal_array_texture(hostDevice, (uint)LayerW, (uint)LayerH, LayerCount, depthFormat == "d16" ? 1 : 2);
				extDepthProps = SDL_CreateProperties();
				SDL_SetPointerProperty(extDepthProps, SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER, mtlDepth);
				layerDepthTex = new Texture(gd, LayerW, LayerH, depthFormat == "d16" ? TextureFormat.Depth16 : TextureFormat.Depth32, LayerCount, TextureFlags.RenderTarget, extDepthProps, "k6d-ext-depth");
			}
		}

		Texture[] attachments = layerDepthTex != null ? [layerColor, layerDepthTex] : [layerColor];
		var samples = hostMsaa switch { 1 => SampleCount.One, 2 => SampleCount.Two, 4 => SampleCount.Four, 8 => SampleCount.Eight, _ => throw new ArgumentException("--msaa expects 1, 2, 4 or 8") };
		var colorMemoryless = memoryless is "color" or "color+depth";
		var depthMemoryless = memoryless == "color+depth";
		if (views == 2)
		{
			// one target over both layers, one pass renders both views
			layer0 = new Target(gd, attachments, 0, samples, multiSampleStore, DepthResolveFilter.Min, colorMemoryless, depthMemoryless, viewCount: 2, name: "k6e-views");
			layer1 = null;
			Log.Info($"[machost] views=2 msaa={hostMsaa} memoryless={memoryless} multiSampleStore={multiSampleStore} depthFormat={depthFormat}: one target with ViewCount {layer0.ViewCount} (colour {(layer0.ColorMemoryless ? "memoryless" : "private")}, depth {(layer0.DepthMemoryless ? "memoryless" : "private")})");
		}
		else if (hostMsaa > 1)
		{
			// MSAA target over the existing layers, resolve into the layers
			layer0 = new Target(gd, attachments, 0, samples, multiSampleStore, DepthResolveFilter.Min, colorMemoryless, depthMemoryless, name: "k6d-layer0");
			layer1 = new Target(gd, attachments, 1, samples, multiSampleStore, DepthResolveFilter.Min, colorMemoryless, depthMemoryless, name: "k6d-layer1");
			Log.Info($"[machost] msaa={hostMsaa} memoryless={memoryless} multiSampleStore={multiSampleStore} depthFormat={depthFormat}: targets created over the layers (colour {(layer0.ColorMemoryless ? "memoryless" : "private")}, depth {(layer0.DepthMemoryless ? "memoryless" : "private")})");
		}
		else
		{
			layer0 = new Target(gd, attachments, 0, "k6d-layer0");
			layer1 = new Target(gd, attachments, 1, "k6d-layer1");
		}
		// one 2D texture per layer: every blit covers its target completely
		previewLeft = new Texture(gd, LayerW, LayerH, TextureFormat.Color, 1, TextureFlags.RenderTarget, 0, "k6d-preview-left");
		previewRight = new Texture(gd, LayerW, LayerH, TextureFormat.Color, 1, TextureFlags.RenderTarget, 0, "k6d-preview-right");
		batcher = new Batcher(gd, "k6d-preview");
		VisionOSKit.Outputs = layer1 != null ? [layer0, layer1] : [layer0];
		VisionOSKit.AfterRender = () =>
		{
			var window = game.Window;
			// 1. window completely black, including the borders next to the preview
			window.Clear(Color.Black);
			// 2. layers 0 and 1 each into their own preview texture (one blit = whole texture).
			//    With a map the pass writes only the physical region of the texture (the clear
			//    too); the rest stays undefined and must not get into the preview
			var src = rateMapPtr != 0 ? new RectInt(0, 0, (int)physW, (int)physH) : new RectInt(0, 0, LayerW, LayerH);
			layerColor.Blit(src, 0, previewLeft, new RectInt(0, 0, LayerW, LayerH), 0, TextureFilter.Nearest);
			layerColor.Blit(src, 1, previewRight, new RectInt(0, 0, LayerW, LayerH), 0, TextureFilter.Nearest);
			// 3. both side by side in one pass (LOAD after the clear), scaled to the window
			Compose(batcher, previewLeft, previewRight, window.SizeInPixels());
			batcher.Render(window);
			batcher.Clear();
		};
		// the host's rate map with two layers; logical = scale x texture size
		Mesh<BatcherVertex>? barsMesh = null;
		if (rateMap)
		{
			if (layers != "external")
				throw new ArgumentException("--rate-map requires --layers external (the map is created on the host device)");
			if (K6dMetal.k6d_metal_supports_rate_map(hostDevice, LayerCount) == 0)
				throw new NotSupportedException($"The device does not support rate maps with {LayerCount} layers");
			logicalW = (int)(LayerW * rateMapScale); logicalH = (int)(LayerH * rateMapScale);
			rateMapPtr = K6dMetal.k6d_metal_rate_map(hostDevice, (uint)logicalW, (uint)logicalH, LayerCount, 16, 0.5f);
			if (rateMapPtr == 0)
				throw new InvalidOperationException("Rate map not created");
			uint sw = 0, sh = 0, lc = 0, pw1 = 0, ph1 = 0;
			K6dMetal.k6d_metal_rate_map_info(rateMapPtr, 0, out sw, out sh, out physW, out physH, out lc);
			K6dMetal.k6d_metal_rate_map_info(rateMapPtr, 1, out _, out _, out pw1, out ph1, out _);
			Log.Info($"[machost] rate map: screen={sw}x{sh} layers={lc} physical layer0={physW}x{physH} layer1={pw1}x{ph1} texture={LayerW}x{LayerH} fits={(physW <= LayerW && physH <= LayerH ? "yes" : "NO (negative test)")} target before setting: logical={layer0.LogicalSize} inPixels={((IDrawableTarget)layer0).WidthInPixels}x{((IDrawableTarget)layer0).HeightInPixels}");
			// negative tests of Foster's checks (the map itself stays valid)
			Selftest2("map with logical size 0", () => layer0.SetRasterizationRateMap(rateMapPtr, 0, 0));
			if (layer1 != null)
				Selftest2("map on a target with layer 1", () => layer1.SetRasterizationRateMap(rateMapPtr, logicalW, logicalH));
			void Selftest2(string what, Action action)
			{
				try { action(); Log.Error($"[machost] selftest '{what}': NO exception (error)"); }
				catch (Exception e) { Log.Info($"[machost] selftest '{what}': rejected ({e.GetType().Name}: {e.Message})"); }
			}
			// measurement image: black image in logical size, five red vertical and three blue
			// horizontal bars, each 6 logical pixels wide, at known logical positions
			var fillMode = new Color(0, 0, 255, 0);
			var blackC = new Color(0, 0, 0, 255); var red = new Color(255, 0, 0, 255); var blue = new Color(0, 0, 255, 255);
			var verts = new List<BatcherVertex>(); var idx = new List<int>();
			void Rect(float x, float y, float w, float h, Color c)
			{
				int b = verts.Count;
				verts.Add(new(new(x, y), c, fillMode)); verts.Add(new(new(x + w, y), c, fillMode));
				verts.Add(new(new(x + w, y + h), c, fillMode)); verts.Add(new(new(x, y + h), c, fillMode));
				idx.AddRange([b, b + 1, b + 2, b, b + 2, b + 3]);
			}
			Rect(0, 0, logicalW, logicalH, blackC);
			foreach (var f in RateMapBars.VerticalFractions) Rect(f * logicalW - 3, 0, 6, logicalH, red);
			foreach (var f in RateMapBars.HorizontalFractions) Rect(0, f * logicalH - 3, logicalW, 6, blue);
			barsMesh = new Mesh<BatcherVertex>(gd, name: "k6e-bars");
			barsMesh.SetVertices((ReadOnlySpan<BatcherVertex>)verts.ToArray());
			barsMesh.SetIndices((ReadOnlySpan<int>)idx.ToArray());
		}

		Mesh<BatcherVertex>? quadMesh = null;
		if (testQuad)
		{
			// in the same pass as the final image: a black field with a slanted green quad in it,
			// as its own draw with depth writes (depth 0 instead of clear 1), so that the resolved
			// depth has different values; Foster's batcher writes no depth
			var fill = new Color(0, 0, 255, 0);   // batcher mode "fill": vertex colour only
			var black = new Color(0, 0, 0, 255); var green = new Color(0, 255, 0, 255);
			float bx = QuadBox.X, by = QuadBox.Y, bw = QuadBox.Width, bh = QuadBox.Height;
			quadMesh = new Mesh<BatcherVertex>(gd, name: "k6d-quad");
			quadMesh.SetVertices((ReadOnlySpan<BatcherVertex>)[
				new(new(bx, by), black, fill), new(new(bx + bw, by), black, fill), new(new(bx + bw, by + bh), black, fill), new(new(bx, by + bh), black, fill),
				new(new(bx + 30, by + 10), green, fill), new(new(bx + 170, by + 25), green, fill), new(new(bx + 150, by + 110), green, fill), new(new(bx + 10, by + 95), green, fill),
			]);
			quadMesh.SetIndices((ReadOnlySpan<int>)[0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]);
		}
		if (quadMesh != null || barsMesh != null)
		{
			VisionOSKit.AfterOutput = output =>
			{
				if (++afterOutputCalls == 1)
					Log.Info($"[machost] AfterOutput first call: output={output.GetType().Name} {output.WidthInPixels}x{output.HeightInPixels} (logical)");
				var material = gd.Defaults.BatchMaterial;
				// projection from the target's size "in pixels": with a map the logical size
				material.Vertex.SetUniformBuffer(System.Numerics.Matrix4x4.CreateOrthographicOffCenter(0, output.WidthInPixels, output.HeightInPixels, 0, 0, float.MaxValue));
				if (quadMesh != null)
					gd.Draw(new DrawCommand(output, quadMesh, material) { DepthTestEnabled = true, DepthWriteEnabled = true, DepthCompare = DepthCompare.Always, CullMode = CullMode.None, BlendMode = BlendMode.Premultiply });
				// measurement image only in the measurement frame, over everything else
				if (barsMesh != null && measureThisFrame)
					gd.Draw(new DrawCommand(output, barsMesh, material) { DepthTestEnabled = false, DepthWriteEnabled = false, CullMode = CullMode.None, BlendMode = BlendMode.Premultiply });
			};
		}
		Log.Info($"[machost] layers={layers}: target {LayerW}x{LayerH} with {LayerCount} layers ({(layerDepthTex != null ? "colour and depth" : "colour only")}), one pass per layer, preview side by side");

		if (layerSelftest)
		{
			// what is impossible on a 2D array must fail clearly instead of running silently wrong
			var probe = new Color[LayerW * LayerH];
			Selftest("GetData without a layer", () => layerColor.GetData<Color>(probe, new RectInt(0, 0, LayerW, LayerH)));
			Selftest("SetData without a layer", () => layerColor.SetData<Color>(probe, new RectInt(0, 0, LayerW, LayerH)));
			Selftest("Blit without a layer", () => layerColor.Blit(previewLeft, TextureFilter.Nearest));
			Selftest("sampling as 2D", () => { batcher.Image(layerColor, Color.White); batcher.Render(game.Window); batcher.Clear(); });
			Selftest("target with layer 2 of 2", () => new Target(gd, attachments, 2));
			void Selftest(string what, Action action)
			{
				try { action(); Log.Error($"[machost] selftest '{what}': NO exception (error)"); }
				catch (Exception e) { Log.Info($"[machost] selftest '{what}': rejected ({e.GetType().Name}: {e.Message})"); }
				finally { batcher.Clear(); }   // a rejected draw otherwise leaves the batch behind
			}
		}
	}
	catch (Exception e) when (e is NotSupportedException or ArgumentException or InvalidOperationException)
	{
		// expected path with SDL 3.4.12 or with a rejected combination: a clear exception,
		// the rest runs in the window
		Log.Warning($"[machost] layers={layers} not possible, continuing with the window: {e.GetType().Name}: {e.Message}");
		VisionOSKit.Outputs = null; VisionOSKit.AfterRender = null; VisionOSKit.AfterOutput = null;
		layerColor?.Dispose(); layerDepthTex?.Dispose();
		layerColor = null; layerDepthTex = null;
	}
}

// A blit into a sub-rectangle must not discard the rest of the target texture
if (blitSelftest)
{
	var gd = game.GraphicsDevice;
	const int W = 64, H = 32;
	var red = new Color[W * H]; var green = new Color[W * H];
	Array.Fill(red, new Color(255, 0, 0, 255)); Array.Fill(green, new Color(0, 255, 0, 255));
	using var srcRed = new Texture(gd, W, H, TextureFormat.Color, 1, TextureFlags.None, 0, "blit-red");
	using var srcGreen = new Texture(gd, W, H, TextureFormat.Color, 1, TextureFlags.None, 0, "blit-green");
	srcRed.SetData<Color>(red); srcGreen.SetData<Color>(green);
	using var dest = new Texture(gd, W * 2, H, TextureFormat.Color, 1, TextureFlags.RenderTarget, 0, "blit-dest");
	srcRed.Blit(new RectInt(0, 0, W, H), dest, new RectInt(0, 0, W, H), TextureFilter.Nearest);
	srcGreen.Blit(new RectInt(0, 0, W, H), dest, new RectInt(W, 0, W, H), TextureFilter.Nearest);
	var result = new Color[W * 2 * H];
	dest.GetData<Color>(result);
	int leftRed = 0, rightGreen = 0;
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W * 2; x++)
		{
			var c = result[y * W * 2 + x];
			if (x < W && c.R == 255 && c.G == 0) leftRed++;
			if (x >= W && c.G == 255 && c.R == 0) rightGreen++;
		}
	var ok = leftRed == W * H && rightGreen == W * H;
	Log.Info($"[machost] blit selftest: left red={leftRed}/{W * H} right green={rightGreen}/{W * H} ({(ok ? "ok" : "ERROR")})");
}

// Observe Celeste's world target (read back colour and depth).
// Set the map on the output target every frame before Celeste draws into it (on the headset
// it comes anew from the compositor per drawable; here it is the same one, the path is the same)
Target? mainTarget = null;
bool rateMapLogged = false;
// Three test quads in view space (x right, y up, -z forward) at 1, 5 and 30 m, drawn with
// Celeste's sprite material (on the reverse-Z path the variant without SV_Depth) and only the
// projection as matrix; depth writes with Always, so the measured value surely comes from the quads
float[] depthPointsMeters = [1f, 5f, 30f];
float[] depthPointTangents = [-0.4f, 0f, 0.4f];
Mesh<Celeste64.SpriteVertex>? depthMesh = null;
Material? depthMaterial = null;
Texture? depthWhite = null;
Matrix depthProjection = Matrix.Identity;
var depthPixels = new (int x, int y)[depthPointsMeters.Length];
VisionOSKit.AfterSceneRender = t =>
{
	mainTarget = t;
	sceneRenderedThisFrame = true;
	if (depthCheckThisFrame && vrDepth)
	{
		var gd = game.GraphicsDevice;
		var near = VisionOSKit.NearUnits;
		depthProjection = VisionOSKit.ProjectionOverride ?? VisionOSKit.ReverseZInfinite(
			Matrix.CreatePerspectiveFieldOfView(MathF.PI / 4.0f, t.Width / (float)t.Height, near, 800f), near);
		if (depthMesh == null)
		{
			depthWhite = new Texture(gd, 1, 1, TextureFormat.Color, 1, TextureFlags.None, 0, "depth-white");
			depthWhite.SetData<Color>([Color.White]);
			depthMaterial = new Material(Assets.Materials["Sprite"]);
			depthMaterial.Fragment.Samplers[0] = new(depthWhite, new TextureSampler(TextureFilter.Nearest, TextureWrap.Clamp, TextureWrap.Clamp));
			var verts = new List<Celeste64.SpriteVertex>(); var idx = new List<int>();
			for (int p = 0; p < depthPointsMeters.Length; p++)
			{
				var d = depthPointsMeters[p] * VisionOSKit.WorldScale;
				var cx = depthPointTangents[p] * d; var half = 0.03f * d;
				int b = verts.Count;
				var tint = new Color((byte)(80 * (p + 1)), 40, 200, 255);
				verts.Add(new(new Vec3(cx - half, -half, -d), Vec2.Zero, tint));
				verts.Add(new(new Vec3(cx + half, -half, -d), Vec2.UnitX, tint));
				verts.Add(new(new Vec3(cx + half, half, -d), Vec2.One, tint));
				verts.Add(new(new Vec3(cx - half, half, -d), Vec2.UnitY, tint));
				idx.AddRange([b, b + 1, b + 2, b, b + 2, b + 3]);
			}
			depthMesh = new Mesh<Celeste64.SpriteVertex>(gd, name: "depth-points");
			depthMesh.SetVertices(CollectionsMarshal.AsSpan(verts));
			depthMesh.SetIndices(CollectionsMarshal.AsSpan(idx));
		}
		for (int p = 0; p < depthPointsMeters.Length; p++)
		{
			var d = depthPointsMeters[p] * VisionOSKit.WorldScale;
			var clip = Vec4.Transform(new Vec4(depthPointTangents[p] * d, 0, -d, 1), depthProjection);
			depthPixels[p] = ((int)((clip.X / clip.W + 1) / 2 * t.Width), (int)((1 - clip.Y / clip.W) / 2 * t.Height));
		}
		depthMaterial!.Vertex.SetUniformBuffer(new Celeste64.UniformBuffers.SpriteVertex(depthProjection));
		depthMaterial.Fragment.SetUniformBuffer(new Celeste64.UniformBuffers.SpriteFragment(new Camera() { Target = t, NearPlane = near, FarPlane = 800f }));
		gd.Draw(new DrawCommand(t, depthMesh, depthMaterial) { DepthTestEnabled = true, DepthWriteEnabled = true, DepthCompare = DepthCompare.Always, CullMode = CullMode.None });
	}
	if (rateMapPtr != 0 && layer0 != null)
	{
		layer0.SetRasterizationRateMap(rateMapPtr, logicalW, logicalH);
		if (!rateMapLogged)
		{
			rateMapLogged = true;
			Log.Info($"[machost] rate map set: Target.LogicalSize={layer0.LogicalSize} Bounds={layer0.Bounds} inPixels={((IDrawableTarget)layer0).WidthInPixels}x{((IDrawableTarget)layer0).HeightInPixels} map=0x{layer0.RasterizationRateMap:x}");
		}
	}
};
var pendingTaps = new List<(long tick, bool down)>();

var clock = Stopwatch.StartNew();
var next = clock.Elapsed;
var secondStart = clock.Elapsed;
long ticks = 0, updates = 0, totalTicks = 0, totalUpdates = 0;
int maxUpdatesPerTick = 0;
long callbacksAtSecondStart = VisionOSKit.CompletedTotal;
bool gapDone = false;
double lastReportedDelta = 0;
var lastWindowedFix = TimeSpan.FromSeconds(-10);
int layerChecks = 0, layerChecksFailed = 0;
var pixels0 = layerColor != null ? new Color[LayerW * LayerH] : null;
var pixels1 = layerColor != null ? new Color[LayerW * LayerH] : null;

while (!game.Exiting && (seconds <= 0 || clock.Elapsed.TotalSeconds < seconds))
{
	// real-time rate: wait for the next tick (sleep coarsely, then spin)
	var now = clock.Elapsed;
	if (now < next)
	{
		var wait = next - now;
		if (wait > TimeSpan.FromMilliseconds(2))
			Thread.Sleep(wait - TimeSpan.FromMilliseconds(1));
		while (clock.Elapsed < next)
			Thread.SpinWait(64);
	}

	// one gap: pause, then exactly one tick, no catching up
	if (gapMs > 0 && !gapDone && clock.Elapsed.TotalSeconds >= 5)
	{
		gapDone = true;
		Thread.Sleep(TimeSpan.FromMilliseconds(gapMs));
		next = clock.Elapsed;
		Log.Info($"[machost] gap {gapMs:F0} ms at t={clock.Elapsed.TotalSeconds:F2} s, next tick without catching up");
	}

	// --windowed: after loading Celeste switches to fullscreen according to the save game; back here
	// (at most once per second, the switch takes several ticks on macOS)
	if (windowed && game.Window.Fullscreen && (clock.Elapsed - lastWindowedFix).TotalSeconds >= 1.0)
	{
		game.Window.Fullscreen = false;
		lastWindowedFix = clock.Elapsed;
		Log.Info("[machost] fullscreen lifted (--windowed)");
	}

	// confirm key at fixed ticks: press in this tick, release in the next
	foreach (var t in tapConfirm)
		if (totalTicks == t) { PushKey(true); pendingTaps.Add((totalTicks + 2, false)); }
	for (int i = pendingTaps.Count - 1; i >= 0; i--)
		if (pendingTaps[i].tick == totalTicks) { PushKey(pendingTaps[i].down); pendingTaps.RemoveAt(i); }
	// key probe F7, press before tick N, release before tick N+2
	if (keyProbeAt >= 0 && totalTicks == keyProbeAt) PushKey(true, SDL_Scancode.SDL_SCANCODE_F7);
	if (keyProbeAt >= 0 && totalTicks == keyProbeAt + 2) PushKey(false, SDL_Scancode.SDL_SCANCODE_F7);
	// pause key (Escape) at a fixed tick, released two ticks later; opens the pause menu in the level
	foreach (var t in tapPause) { if (totalTicks == t) PushKey(true, SDL_Scancode.SDL_SCANCODE_ESCAPE); if (totalTicks == t + 2) PushKey(false, SDL_Scancode.SDL_SCANCODE_ESCAPE); }
	// held keys (movement) between two ticks
	foreach (var h in holdKeys) { if (totalTicks == h.from) PushKey(true, h.key); if (totalTicks == h.to) PushKey(false, h.key); }
	// menu Down at fixed ticks (released two ticks later), e.g. to reach Retry in the pause menu
	foreach (var t in tapDown) { if (totalTicks == t) PushKey(true, SDL_Scancode.SDL_SCANCODE_DOWN); if (totalTicks == t + 2) PushKey(false, SDL_Scancode.SDL_SCANCODE_DOWN); }
	// simulated gamepad: connected from the first tick, lost between the two ticks of --gamepad-sim
	if (gamepadSim is { } sim)
		VisionOSKit.GamepadPrompt.SimulatedConnected = totalTicks < sim.from || totalTicks >= sim.to;

	// simulate an uneven wall clock; the tick still gets the grid delta
	if (jitterMs > 0)
		Thread.Sleep(TimeSpan.FromMilliseconds(jitterRng.NextDouble() * jitterMs));

	if (metalCapturePath != null && totalTicks == metalCaptureTick)
	{
		var ok = K6dMetal.k6d_metal_capture_start(hostDevice != 0 ? hostDevice : K6dMetal.k6d_metal_device(), metalCapturePath);
		Log.Info($"[machost] metal capture tick={totalTicks} path={metalCapturePath} started={ok}");
	}
	var frameBefore = game.Time.Frame;
	// minimize and restore the window (SDL window handle through SDL_GetWindows, Foster does not
	// expose it); without a swapchain image no pass may fail
	if (minimizeAt.Count >= 1 && totalTicks == minimizeAt[0])
	{
		var windows = SDL_GetWindows();
		if (windows.Length > 0) { SDL_MinimizeWindow(windows[0]); Log.Info($"[machost] window minimized at tick {totalTicks}"); }
	}
	if (minimizeAt.Count >= 2 && totalTicks == minimizeAt[1])
	{
		var windows = SDL_GetWindows();
		if (windows.Length > 0) { SDL_RestoreWindow(windows[0]); Log.Info($"[machost] window restored at tick {totalTicks}"); }
	}
	// measurement frame (bar image instead of Celeste) halfway between two layer comparisons
	measureThisFrame = rateMapPtr != 0 && layerCheck > 0 && (totalTicks + 1) % layerCheck == layerCheck / 2;
	depthCheckThisFrame = depthCheck > 0 && totalTicks > 0 && totalTicks % depthCheck == 0;
	sceneRenderedThisFrame = false;
	// before the tick hand the host's "drawable" to Celeste; evaluate after the tick
	if (vrWorld && mtlColor != 0 && mtlDepth != 0)
	{
		var eye0 = VisionOSKit.CreateProjectionFromTangents(1.732f, 1.0f, 1.0f, 1.192f);
		var eye1 = VisionOSKit.CreateProjectionFromTangents(1.0f, 1.732f, 1.0f, 1.192f);
		var hasMap = rateMapPtr != 0;
		var headRot = Matrix.Identity;
		// eyes 0.064 m apart (left eye at -x), head at O, culling from the union of both eyes
		VisionOSKit.BeginVRFrame(game.GraphicsDevice, mtlColor, mtlDepth, LayerW, LayerH, LayerCount, colorSrgb: false,
			hasMap ? rateMapPtr : 0, hasMap ? logicalW : LayerW, hasMap ? logicalH : LayerH, hasMap ? (int)physW : LayerW, hasMap ? (int)physH : LayerH,
			eye0, eye1,
			Matrix.CreateTranslation(-StereoIpd / 2, 0, 0) * headRot, Matrix.CreateTranslation(StereoIpd / 2, 0, 0) * headRot, headRot,
			VisionOSKit.UnionProjection(eye0, eye1), originReset: totalTicks == 0);
	}
	try
	{
		game.Tick(delta, present: !noPresent);
	}
	catch (InvalidOperationException e)
	{
		// a rejected pass (for example a map physically larger than the texture) comes out of
		// Foster as a clear exception; the run ends here, the text is the result
		Log.Error($"[machost] tick aborted: {e.GetType().Name}: {e.Message}");
		layerChecksFailed++;
		break;
	}
	// result of this tick's world pass
	if (vrWorld && VisionOSKit.Frame != null)
	{
		var (rendered, flushes) = VisionOSKit.EndVRFrame();
		if (rendered) { if (vrWorldFrames++ == 0) Log.Info($"[machost] vr world: first world frame at tick {totalTicks} (frame {game.Time.Frame}), flushes={flushes}"); }
		else vrCanvasFrames++;
		// performance: labels of this tick's buffers (upload and render per submission)
		if (gpuPasses)
		{
			if (rendered && flushes == 3) GpuPassTimer.Expect(["world", "world", "edge", "edge", "sprites", "sprites", "rest", "rest"], rendered);
			else if (!rendered && flushes == 0) GpuPassTimer.Expect(["canvas", "canvas"], rendered);
			else { var l = new List<string>(); for (int i = 0; i <= flushes; i++) { l.Add($"pass{i}"); l.Add($"pass{i}"); } GpuPassTimer.Expect(l, rendered); }
		}
	}
	if (metalCapturePath != null && totalTicks == metalCaptureTick)
	{
		K6dMetal.k6d_metal_capture_stop();
		Log.Info($"[machost] metal capture stopped: {metalCapturePath}");
	}

	// evaluate the measurement image, both layers, expected values from the map
	if (measureThisFrame && layerColor != null && pixels0 != null && pixels1 != null)
	{
		var rect = new RectInt(0, 0, LayerW, LayerH);
		layerColor.GetData<Color>(pixels0, rect, 0);
		layerColor.GetData<Color>(pixels1, rect, 1);
		float maxDev = 0, sumDev = 0; int samples = 0, missing = 0;
		for (int layerIndex = 0; layerIndex < LayerCount; layerIndex++)
		{
			var px = layerIndex == 0 ? pixels0 : pixels1;
			float layerMax = 0;
			// vertical red bars: expected x from the map, actual from three physical rows
			foreach (var f in RateMapBars.VerticalFractions)
			{
				K6dMetal.k6d_metal_rate_map_screen_to_physical(rateMapPtr, (uint)layerIndex, f * logicalW, logicalH / 2f, out var ex, out _);
				foreach (var rf in RateMapBars.RowFractions)
				{
					K6dMetal.k6d_metal_rate_map_screen_to_physical(rateMapPtr, (uint)layerIndex, logicalW / 2f, rf * logicalH, out _, out var ry);
					int row = Math.Clamp((int)ry, 0, (int)physH - 1);
					double sum = 0; int n = 0;
					for (int x = 0; x < (int)physW && x < LayerW; x++)
					{
						var c = px[row * LayerW + x];
						if (c.R == 255 && c.G == 0 && c.B == 0 && Math.Abs(x + 0.5f - ex) < 10) { sum += x + 0.5; n++; }
					}
					Measure(n, n > 0 ? (float)(sum / n) : float.NaN, ex, ref layerMax);
				}
			}
			// horizontal blue bars: expected y from the map, actual from three physical columns
			foreach (var f in RateMapBars.HorizontalFractions)
			{
				K6dMetal.k6d_metal_rate_map_screen_to_physical(rateMapPtr, (uint)layerIndex, logicalW / 2f, f * logicalH, out _, out var ey);
				foreach (var cf in RateMapBars.ColumnFractions)
				{
					K6dMetal.k6d_metal_rate_map_screen_to_physical(rateMapPtr, (uint)layerIndex, cf * logicalW, logicalH / 2f, out var cx, out _);
					int col = Math.Clamp((int)cx, 0, (int)physW - 1);
					double sum = 0; int n = 0;
					for (int y = 0; y < (int)physH && y < LayerH; y++)
					{
						var c = px[y * LayerW + col];
						if (c.B == 255 && c.R == 0 && c.G == 0 && Math.Abs(y + 0.5f - ey) < 10) { sum += y + 0.5; n++; }
					}
					Measure(n, n > 0 ? (float)(sum / n) : float.NaN, ey, ref layerMax);
				}
			}
			Log.Info($"[machost] ratemap check layer{layerIndex} frame={game.Time.Frame} maxDevPx={layerMax:F3}");
			void Measure(int count, float actual, float expected, ref float layerMaximum)
			{
				samples++;
				if (count == 0) { missing++; return; }
				var dev = Math.Abs(actual - expected);
				sumDev += dev; if (dev > maxDev) maxDev = dev; if (dev > layerMaximum) layerMaximum = dev;
			}
		}
		var found = samples - missing;
		var ok = missing == 0 && maxDev <= 1.0f;
		layerChecks++;
		if (!ok) layerChecksFailed++;
		Log.Info($"[machost] ratemap check frame={game.Time.Frame} logical={logicalW}x{logicalH} physical={physW}x{physH} samples={samples} missing={missing} maxDevPx={maxDev:F3} meanDevPx={(found > 0 ? sumDev / found : 0):F3} ({(ok ? "ok" : "ERROR")})");
	}

	// read the depth of the test quads back (Depth32 of the reverse-Z path), near/d against the distance
	if (depthCheckThisFrame && mainTarget != null && mainTarget.Attachments.Length > 1)
	{
		depthChecks++;
		if (!sceneRenderedThisFrame)
		{
			// wipe (Perform or Hold): Game.Render does not draw the scene, the world target shows the
			// last frame without test quads; not judged
			Log.Info($"[machost] depth check frame={game.Time.Frame}: no scene render in this frame (wipe), skipped");
			depthChecks--;
		}
		else if (!vrDepth || mainTarget.Attachments[1].Format != TextureFormat.Depth32)
		{
			Log.Warning($"[machost] depth check frame={game.Time.Frame}: requires --vr-depth (Depth32), format is {mainTarget.Attachments[1].Format}");
			depthChecksFailed++;
		}
		else
		{
			var tw = mainTarget.Width; var th = mainTarget.Height;
			var depth = new float[tw * th];
			mainTarget.Attachments[1].GetData<float>(depth, new RectInt(0, 0, tw, th));
			var nearM = VisionOSKit.NearMeters;
			bool ok = true;
			for (int p = 0; p < depthPointsMeters.Length; p++)
			{
				var (px, py) = depthPixels[p];
				var d = px >= 0 && py >= 0 && px < tw && py < th ? depth[py * tw + px] : float.NaN;
				var distance = d > 0 ? nearM / d : double.PositiveInfinity;
				var dev = Math.Abs(distance - depthPointsMeters[p]) / depthPointsMeters[p] * 100;
				var pointOk = dev <= 1.0;
				ok &= pointOk;
				Log.Info($"[machost] depth point frame={game.Time.Frame} D={depthPointsMeters[p]:F1} m pixel=({px},{py}) d={d:E4} near/d={distance:F4} m dev={dev:F4}% ({(pointOk ? "ok" : "ERROR")})");
			}
			float dmin = float.MaxValue, dmax = 0; long zero = 0;
			foreach (var v in depth) { if (v <= 0) { zero++; continue; } if (v < dmin) dmin = v; if (v > dmax) dmax = v; }
			// sky: cube with half edge R and Z factor 0.5, so distances R/2 to R·1.5: depth near/(1.5 R) to near/(0.5 R)
			var skyLo = nearM / (VisionOSKit.SkyRadiusMeters * 1.5); var skyHi = nearM / (VisionOSKit.SkyRadiusMeters * 0.5);
			// in the level (Game keeps its scenes private): after the last confirm key plus loading
			// time and wipe (120 ticks), otherwise title or overworld without a sky
			var inWorld = tapConfirm.Count > 0 && totalTicks > tapConfirm[^1] + 300;
			var skyOk = !inWorld || (zero == 0 && dmin >= skyLo * 0.99 && dmin <= skyHi * 1.01);
			ok &= skyOk;
			Log.Info($"[machost] depth sky frame={game.Time.Frame} inWorld={inWorld} zero={zero} of {depth.Length} minDepth={(zero == depth.Length ? 0 : dmin):E4} (= {(dmin > 0 && dmin < float.MaxValue ? nearM / dmin : 0):F0} m) maxDepth={dmax:E4} (= {(dmax > 0 ? nearM / dmax : 0):F3} m) dome={skyLo:E3}..{skyHi:E3} ({(skyOk ? "ok" : "ERROR")}{(inWorld ? "" : ", evaluated only in the level")})");
			if (!ok) depthChecksFailed++;
		}
	}

	// read the world target back: colour (resolve texture) and depth (with MSAA the resolve depth)
	if (targetCheck > 0 && mainTarget != null && totalTicks % targetCheck == 0)
	{
		var tw = mainTarget.Width; var th = mainTarget.Height;
		var color = new Color[tw * th];
		mainTarget.Attachments[0].GetData<Color>(color, new RectInt(0, 0, tw, th));
		int magenta = 0, nonBlack = 0;
		foreach (var c in color)
		{
			if (c.R > 200 && c.G < 50 && c.B > 200) magenta++;
			if (c.R + c.G + c.B > 0) nonBlack++;
		}
		string depthInfo = "-";
		if (mainTarget.Attachments.Length > 1)
		{
			try
			{
				if (mainTarget.Attachments[1].Format == TextureFormat.Depth32)
				{
					// reverse-Z path with float depth
					var depth = new float[tw * th];
					mainTarget.Attachments[1].GetData<float>(depth, new RectInt(0, 0, tw, th));
					float dmin = float.MaxValue, dmax = 0; var distinct = new HashSet<float>(); long zero = 0, full = 0;
					foreach (var d in depth) { if (d < dmin) dmin = d; if (d > dmax) dmax = d; distinct.Add(d); if (d == 0) zero++; if (d == 1) full++; }
					depthInfo = $"d32 min={dmin:E3} max={dmax:E3} distinct={distinct.Count} zero={zero} one={full} sampler={(mainTarget.Attachments[1].SampleCount != SampleCount.One ? "resolve" : "1x")}";
				}
				else
				{
					var depth = new ushort[tw * th];
					mainTarget.Attachments[1].GetData<ushort>(depth, new RectInt(0, 0, tw, th));
					ushort dmin = ushort.MaxValue, dmax = 0; var distinct = new HashSet<ushort>(); long zero = 0, full = 0;
					foreach (var d in depth) { if (d < dmin) dmin = d; if (d > dmax) dmax = d; distinct.Add(d); if (d == 0) zero++; if (d == ushort.MaxValue) full++; }
					depthInfo = $"min={dmin} max={dmax} distinct={distinct.Count} zero={zero} full={full} sampler={(mainTarget.Attachments[1].SampleCount != SampleCount.One ? "resolve" : "1x")}";
				}
			}
			catch (Exception e) { depthInfo = $"error: {e.GetType().Name}: {e.Message}"; }
		}
		Log.Info($"[machost] target check frame={game.Time.Frame} size={tw}x{th} samples={mainTarget.Attachments[0].SampleCount} magenta={magenta} nonBlack={nonBlack} of {color.Length} depth[{depthInfo}]");
		if (targetDump != null)
		{
			var path = $"{targetDump}-{game.Time.Frame}.ppm";
			using var f = new FileStream(path, FileMode.Create);
			var header = System.Text.Encoding.ASCII.GetBytes($"P6\n{tw} {th}\n255\n");
			f.Write(header);
			var bytes = new byte[tw * th * 3];
			for (int i = 0; i < color.Length; i++) { bytes[i * 3] = color[i].R; bytes[i * 3 + 1] = color[i].G; bytes[i * 3 + 2] = color[i].B; }
			f.Write(bytes);
			// also raw RGBA (rows from the top) for scripts/compare-canvas.py --width <width>
			var rawPath = $"{targetDump}-{game.Time.Frame}.rgba";
			var raw = new byte[tw * th * 4];
			for (int i = 0; i < color.Length; i++) { raw[i * 4] = color[i].R; raw[i * 4 + 1] = color[i].G; raw[i * 4 + 2] = color[i].B; raw[i * 4 + 3] = color[i].A; }
			File.WriteAllBytes(rawPath, raw);
			Log.Info($"[machost] target dump {path} and {rawPath} ({tw}x{th})");
		}
	}
	// after which tick does Foster see the probe? (state after tick totalTicks)
	if (keyProbeAt >= 0 && totalTicks >= keyProbeAt)
	{
		var down = game.Input.Keyboard.Down(Keys.F7);
		if (down && keyProbeSeenDown < 0) { keyProbeSeenDown = totalTicks; Log.Info($"[machost] key probe: F7 injected before tick {keyProbeAt}, seen as pressed after tick {totalTicks} (delay {totalTicks - keyProbeAt})"); }
		if (!down && keyProbeSeenDown >= 0 && keyProbeSeenUp < 0) { keyProbeSeenUp = totalTicks; Log.Info($"[machost] key probe: F7 released before tick {keyProbeAt + 2}, seen as released after tick {totalTicks} (delay {totalTicks - keyProbeAt - 2})"); }
	}
	var stepped = (int)(game.Time.Frame - frameBefore);
	ticks++; totalTicks++;
	updates += stepped; totalUpdates += stepped;
	maxUpdatesPerTick = Math.Max(maxUpdatesPerTick, stepped);
	lastReportedDelta = game.Time.Delta;

	// layer comparison: read both layers back, count the pixels that differ
	if (layerColor != null && pixels0 != null && pixels1 != null && ((layerCheck > 0 && totalTicks % layerCheck == 0) || layerDumpTicks.Contains(totalTicks)))
	{
		var rect = new RectInt(0, 0, LayerW, LayerH);
		layerColor.GetData<Color>(pixels0, rect, 0);
		layerColor.GetData<Color>(pixels1, rect, 1);
		int diff = 0, nonBlack0 = 0, nonBlack1 = 0;
		for (int i = 0; i < pixels0.Length; i++)
		{
			if (pixels0[i] != pixels1[i]) diff++;
			if (pixels0[i].R + pixels0[i].G + pixels0[i].B > 0) nonBlack0++;
			if (pixels1[i].R + pixels1[i].G + pixels1[i].B > 0) nonBlack1++;
		}
		layerChecks++;
		// in the stereo world pass the layers differ (projection per eye): only content is required
		var layersOk = vrWorld ? (nonBlack0 > 0 && nonBlack1 > 0) : (diff == 0 && nonBlack0 > 0);
		if (!layersOk) layerChecksFailed++;
		Log.Info($"[machost] layers check #{layerChecks} frame={game.Time.Frame} diff={diff} of {pixels0.Length} nonBlack0={nonBlack0} nonBlack1={nonBlack1} ({(layersOk ? "ok" : "ERROR")}{(vrWorld ? ", world pass: layers may differ" : "")})");
		Log.Info($"[machost] frame stats: views={views} passes/frame={game.GraphicsDevice.RenderPassesLastFrame} draws/frame={game.GraphicsDevice.DrawCallsLastFrame}");

		// both layers (physical region) as raw RGBA for compare-canvas.py
		if (layerDump != null)
		{
			var dumpRect = rateMapPtr != 0 ? new RectInt(0, 0, (int)physW, (int)physH) : rect;
			for (int layerIndex = 0; layerIndex < LayerCount; layerIndex++)
			{
				var px = new Color[dumpRect.Width * dumpRect.Height];
				layerColor.GetData<Color>(px, dumpRect, layerIndex);
				var raw = new byte[px.Length * 4];
				for (int i = 0; i < px.Length; i++) { raw[i * 4] = px[i].R; raw[i * 4 + 1] = px[i].G; raw[i * 4 + 2] = px[i].B; raw[i * 4 + 3] = px[i].A; }
				var path = $"{layerDump}-L{layerIndex}-{game.Time.Frame}.rgba";
				File.WriteAllBytes(path, raw);
				Log.Info($"[machost] layer dump {path} ({dumpRect.Width}x{dumpRect.Height})");
			}
		}

		// Pixel look: drawable layer 0 (physical) against the coarse target B. The magnification pass
		// takes for every logical pixel the coarse texel (nearest) its position falls into; with a map
		// the decoder converts physical -> logical (the map is separable per axis, assumption as for
		// MTLRasterizationRateLayerDescriptor: column values from the middle row, row values from the
		// middle column). Every drawable pixel must carry exactly its texel; at block borders the
		// rounding may hit the neighbouring texel. Also the block width along the middle row in
		// logical pixels: equal across the image, expectation logical width / width of B.
		// Drawable layer 0 against A (only outline pixels
		// differ), plus the outline width: horizontal runs of outline pixels (drawable darker than A
		// in all channels), most frequent run length in the image centre (±15 % of the logical width)
		// and at the border (outer 25 %), expectation angle·(1+x²+y²)·k_logical/rate in physical pixels
		// (rate = logical per physical pixel from the decoder, 1 without a map)
		if (vrCheck && vrWorldFrames > 0 && VisionOSKit.Intermediate is { } worldA)
		{
			vrChecks++;
			var checkRect = rateMapPtr != 0 ? new RectInt(0, 0, (int)physW, (int)physH) : rect;
			int w = checkRect.Width, h = checkRect.Height;
			var aPixels = new Color[w * h];
			var dPixels = new Color[w * h];
			worldA.Attachments[0].GetData<Color>(aPixels, checkRect, 0);
			layerColor.GetData<Color>(dPixels, checkRect, 0);
			if (coarseDump != null)
			{
				// A (resolved colour, layer 0) as raw RGBA, comparison of two runs (with and without discard)
				var raw = new byte[aPixels.Length * 4];
				for (int i = 0; i < aPixels.Length; i++) { raw[i * 4] = aPixels[i].R; raw[i * 4 + 1] = aPixels[i].G; raw[i * 4 + 2] = aPixels[i].B; raw[i * 4 + 3] = aPixels[i].A; }
				var dumpPath = $"{coarseDump}-A-L0-{game.Time.Frame}.rgba";
				File.WriteAllBytes(dumpPath, raw);
				Log.Info($"[machost] coarse dump {dumpPath} ({w}x{h}, msaa={VisionOSKit.PixelMsaa}, nodiscard={(VisionOSKit.NoDiscard ? 1 : 0)})");
			}
			float logW = rateMapPtr != 0 ? logicalW : LayerW, logH = rateMapPtr != 0 ? logicalH : LayerH;
			var sx = new float[w + 1];
			var sy = new float[h];
			for (int px = 0; px <= w; px++) { sx[px] = px + 0.5f; if (rateMapPtr != 0) K6dMetal.k6d_metal_rate_map_physical_to_screen(rateMapPtr, 0, px + 0.5f, h / 2 + 0.5f, out sx[px], out _); }
			for (int py = 0; py < h; py++) { sy[py] = py + 0.5f; if (rateMapPtr != 0) K6dMetal.k6d_metal_rate_map_physical_to_screen(rateMapPtr, 0, w / 2 + 0.5f, py + 0.5f, out _, out sy[py]); }
			const float tanL = 1.732f, tanR = 1.0f, tanT = 1.0f, tanB = 1.192f;
			var edgeRad = VisionOSKit.EdgeAngleDegrees * MathF.PI / 180f;
			var kx = logW / (tanL + tanR);
			int differing = 0, outlined = 0;
			// three zones in logical coordinates: left (outer 25 %), centre (±15 %), right (outer
			// 25 %); per zone a histogram of the run lengths and the mean expectation (the MacHost's map
			// has rate 1 on the left and rate 2 on the right, the zones must not be mixed)
			var hists = new[] { new int[41], new int[41], new int[41] };
			var expSum = new double[3]; var expN = new int[3];
			var zoneNames = new[] { "left", "centre", "right" };
			// outline pixels exactly: drawable = 0.3·A + 0.7·outline colour (0x110d33), tolerance 2 per channel
			// (shader rounding); so sprites and shadows that enter the drawable after the edge pass and
			// also darken A do not count as outline
			static bool IsOutline(Color d, Color a)
			{
				int er = (int)MathF.Round(0.3f * a.R + 0.7f * 0x11), eg = (int)MathF.Round(0.3f * a.G + 0.7f * 0x0d), eb = (int)MathF.Round(0.3f * a.B + 0.7f * 0x33);
				return Math.Abs(d.R - er) <= 2 && Math.Abs(d.G - eg) <= 2 && Math.Abs(d.B - eb) <= 2 && (a.R - d.R >= 4 || a.G - d.G >= 4 || a.B - d.B >= 4);
			}
			for (int py = 0; py < h; py++)
			{
				var yt = tanT - sy[py] / logH * (tanT + tanB);
				int runStart = -1;
				for (int px = 0; px <= w; px++)
				{
					bool outline = false;
					if (px < w)
					{
						var a = aPixels[py * w + px]; var d = dPixels[py * w + px];
						if (a != d) { differing++; if (d.R <= a.R && d.G <= a.G && d.B <= a.B) outlined++; }
						outline = IsOutline(d, a);
					}
					if (outline) { if (runStart < 0) runStart = px; continue; }
					if (runStart < 0) continue;
					int len = px - runStart, mid = (runStart + px) / 2;
					runStart = -1;
					if (len > 40) continue;
					var x = sx[Math.Min(mid, w - 1)];
					var rate = Math.Max(sx[Math.Min(mid + 1, w)] - sx[Math.Min(mid, w - 1)], 1e-3f);
					var xt = -tanL + x / logW * (tanL + tanR);
					var expected = edgeRad * (1 + xt * xt + yt * yt) * kx / rate;
					int zone = x < 0.25f * logW ? 0 : Math.Abs(x - logW / 2) < 0.15f * logW ? 1 : x > 0.75f * logW ? 2 : -1;
					if (zone < 0) continue;
					hists[zone][len]++; expSum[zone] += expected; expN[zone]++;
				}
			}
			// Outline pixels by depth zones and on flat pixels. Raw reverse-Z depth of A (n'/z), zones
			// by view distance z = n'/D in units (10 per metre): near below 50, far above 150; "flat"
			// means the Laplacian of the raw depth (4·D − neighbours) below a tenth of the raw threshold.
			// With the reference's criterion flat pixels may carry no outline; the old criterion marks
			// distant slanted surfaces
			{
				var depthA = new float[w * h];
				worldA.Attachments[1].GetData<float>(depthA, checkRect, 0);
				var nearUnits = VisionOSKit.NearUnits;
				var flatLimit = VisionOSKit.RawEdgeThreshold * 0.1f;
				// "flat" with the same star as the shader: neighbours at the distance of the angular width
				// in physical pixels at this place (a pixel next to a depth step lies on a plane itself
				// but belongs to the outline band); a pixel is flat when its Laplacian with this star
				// stays below a tenth of the raw threshold
				long nearN = 0, nearOut = 0, farN = 0, farOut = 0, flatN = 0, flatOut = 0, flatFarN = 0, flatFarOut = 0;
				for (int py = 1; py < h - 1; py++)
				{
					var ytFlat = tanT - sy[py] / logH * (tanT + tanB);
					for (int px = 1; px < w - 1; px++)
					{
						int i = py * w + px;
						var dv = depthA[i];
						if (dv <= 1e-7f) continue;   // sky far away or nothing drawn
						var z = nearUnits / dv;
						var outline = IsOutline(dPixels[i], aPixels[i]);
						// star like the shader: offset in physical pixels per axis (angle · Jacobian · pixels per
						// tangent / rate), nearest sampling at (pixel centre ± offset), so floor(px + 0.5 ± h)
						var rateX = Math.Max(sx[px + 1] - sx[px], 1e-3f);
						var rateY = Math.Max((py + 1 < h ? sy[py + 1] : sy[py] + (sy[py] - sy[py - 1])) - sy[py], 1e-3f);
						var xtFlat = -tanL + sx[px] / logW * (tanL + tanR);
						var jac = 1 + xtFlat * xtFlat + ytFlat * ytFlat;
						var hxF = edgeRad * jac * kx / rateX;
						var hyF = edgeRad * jac * (logH / (tanT + tanB)) / rateY;
						int xl = (int)MathF.Floor(px + 0.5f - hxF), xr = (int)MathF.Floor(px + 0.5f + hxF);
						int yu = (int)MathF.Floor(py + 0.5f - hyF), yd = (int)MathF.Floor(py + 0.5f + hyF);
						if (xl < 0 || xr >= w || yu < 0 || yd >= h) continue;
						var lap = Math.Abs(4 * dv - depthA[py * w + xl] - depthA[py * w + xr] - depthA[yu * w + px] - depthA[yd * w + px]) * 0.25f;
						var flat = lap < flatLimit;
						if (z < 50) { nearN++; if (outline) nearOut++; }
						else if (z > 150) { farN++; if (outline) farOut++; }
						if (flat) { flatN++; if (outline) flatOut++; if (z > 150) { flatFarN++; if (outline) flatFarOut++; } }
					}
				}
				double Pct(long a, long n) => n > 0 ? a * 100.0 / n : 0;
				// rounding of the star (the shader samples at non-integer offsets): below 0.02 % counts as 0
				var flatOk = Pct(flatFarOut, flatFarN) < 0.02;
				if (!flatOk) vrChecksFailed++;
				Log.Info($"[machost] edge zones criterion=raw rawThreshold={VisionOSKit.RawEdgeThreshold:E2} outline near(z<5m)={Pct(nearOut, nearN):F2}% (n={nearN}) far(z>15m)={Pct(farOut, farN):F2}% (n={farN}) flat={Pct(flatOut, flatN):F3}% (n={flatN}) flatFar={Pct(flatFarOut, flatFarN):F3}% (n={flatFarN}, outline={flatFarOut}) ({(flatOk ? "ok" : "ERROR")})");
			}
			// diagnostics (C64_STEREO_TESTFILL=rate): the rate painted by the shader (red = x/4) against
			// the decoder's rate at five columns of the middle row
			if (VisionOSKit.StereoTestRate)
			{
				var parts = new List<string>();
				foreach (var f in new[] { 0.05f, 0.25f, 0.5f, 0.75f, 0.95f })
				{
					int px = Math.Clamp((int)(f * w), 0, w - 1);
					var d = dPixels[(h / 2) * w + px];
					var cpuRate = sx[px + 1] - sx[px];
					parts.Add($"x={px}: gpu={d.R / 255f * 4:F2} cpu={cpuRate:F2}");
				}
				Log.Info($"[machost] rate probe (shader vs decoder, logical px per physical px): {string.Join(" | ", parts)}");
			}
			int Mode(int[] hist) { int best = 0; for (int i = 1; i < hist.Length; i++) if (hist[i] > hist[best]) best = i; return best; }
			string Hist(int[] hist) => string.Join(",", hist.Skip(1).Take(10));
			var fraction = differing / (double)(w * h) * 100;
			// per zone: most frequent run length against the expectation, tolerance 0.75 px or 30 %. Centre
			// and right are judged (there the scene at frame 900 has many vertical edges, the histogram
			// a clear peak); on the left the histogram is flat (slanted edges, few runs) and is only
			// printed. Zones with fewer than 100 runs do not count.
			var widthOk = true; var zoneText = new List<string>();
			for (int z = 0; z < 3; z++)
			{
				var mode = Mode(hists[z]);
				var expected = expN[z] > 0 ? expSum[z] / expN[z] : 0;
				var judged = z > 0 && expN[z] >= 100;
				var ok = !judged || Math.Abs(mode - expected) <= Math.Max(0.75, 0.3 * expected);
				if (!ok) widthOk = false;
				zoneText.Add($"{zoneNames[z]} mode={mode} expected={expected:F2} n={expN[z]} hist1..10=[{Hist(hists[z])}]{(judged ? "" : " (not judged)")}");
			}
			var vrOk = fraction < 10 && widthOk;
			if (!vrOk) vrChecksFailed++;
			Log.Info($"[machost] vr check #{vrChecks} frame={game.Time.Frame} world region={w}x{h} msaa={VisionOSKit.PixelMsaa} differing={differing} ({fraction:F2}%) outlineLike={outlined} edge={VisionOSKit.EdgeAngleDegrees:F3}deg width(phys px) {string.Join(" | ", zoneText)} negative={(VisionOSKit.StereoNegativeNoAngle ? 1 : 0)} ({(vrOk ? "ok" : "ERROR")})");
		}
		// test quad: count in the black field how many pixels are pure green and how many have
		// intermediate values (only with MSAA > 0)
		if (testQuad)
		{
			// counting region: the field is drawn logically; with a map its image lies in physical
			// space, so map the corners through the map
			int qx0 = QuadBox.X, qy0 = QuadBox.Y, qx1 = QuadBox.X + QuadBox.Width, qy1 = QuadBox.Y + QuadBox.Height;
			if (rateMapPtr != 0)
			{
				K6dMetal.k6d_metal_rate_map_screen_to_physical(rateMapPtr, 0, qx0, qy0, out var px0, out var py0);
				K6dMetal.k6d_metal_rate_map_screen_to_physical(rateMapPtr, 0, qx1, qy1, out var px1, out var py1);
				qx0 = (int)MathF.Ceiling(px0) + 1; qy0 = (int)MathF.Ceiling(py0) + 1; qx1 = (int)MathF.Floor(px1) - 1; qy1 = (int)MathF.Floor(py1) - 1;
			}
			int full = 0, partial = 0, other = 0;
			for (int y = qy0; y < qy1; y++)
				for (int x = qx0; x < qx1; x++)
				{
					var c = pixels0[y * LayerW + x];
					if (c.R == 0 && c.B == 0 && c.G == 255) full++;
					else if (c.R == 0 && c.B == 0 && c.G > 0) partial++;
					else if (!(c.R == 0 && c.G == 0 && c.B == 0)) other++;
				}
			Log.Info($"[machost] quad check #{layerChecks} msaa={hostMsaa} afterOutputCalls={afterOutputCalls} region={qx0},{qy0}-{qx1},{qy1}{(rateMapPtr != 0 ? " (physical from the map)" : "")} full={full} partial={partial} other={other} ({(hostMsaa > 1 ? (partial > 0 ? "ok" : "ERROR") : (partial == 0 ? "ok" : "ERROR"))})");
			if ((hostMsaa > 1) != (partial > 0)) layerChecksFailed++;
		}

		// external depth: after the resolve it must be written (not only the clear value)
		if (layerDepthTex != null)
		{
			try
			{
				// with a map only the physical region (outside it the pass writes nothing)
				var drect = rateMapPtr != 0 ? new RectInt(0, 0, (int)physW, (int)physH) : rect;
				for (int layerIndex = 0; layerIndex < LayerCount; layerIndex++)
				{
					string info;
					if (layerDepthTex.Format == TextureFormat.Depth16)
					{
						var d = new ushort[drect.Width * drect.Height]; layerDepthTex.GetData<ushort>(d, drect, layerIndex);
						var set = new HashSet<ushort>(d); info = $"d16 distinct={set.Count} min={d.Min()} max={d.Max()}";
					}
					else
					{
						var d = new float[drect.Width * drect.Height]; layerDepthTex.GetData<float>(d, drect, layerIndex);
						var set = new HashSet<float>(d); info = $"d32 distinct={set.Count} min={d.Min():F4} max={d.Max():F4}";
					}
					Log.Info($"[machost] depth check #{layerChecks} layer{layerIndex} region={drect.Width}x{drect.Height} {info}");
				}
			}
			catch (Exception e) { Log.Warning($"[machost] depth check: {e.GetType().Name}: {e.Message}"); }
		}

		// composition check: the same preview as in the window into an offscreen target of window
		// size, read back, count magenta, compare the halves, check the borders
		if (previewLeft != null && previewRight != null && batcher != null)
		{
			var size = game.Window.SizeInPixels();
			if (composeCheck == null || composeCheck.Width != size.X || composeCheck.Height != size.Y)
			{
				composeCheck?.Dispose();
				composeCheck = new Target(game.GraphicsDevice, size.X, size.Y, "k6d-compose-check");
			}
			composeCheck.Clear(Color.Black);
			Compose(batcher, previewLeft, previewRight, size);
			batcher.Render(composeCheck);
			batcher.Clear();
			var shot = new Color[size.X * size.Y];
			composeCheck.Attachments[0].GetData<Color>(shot, new RectInt(0, 0, size.X, size.Y));
			int magenta = 0, nonBlack = 0, halvesDiffer = 0;
			int half = size.X / 2;
			for (int y = 0; y < size.Y; y++)
				for (int x = 0; x < size.X; x++)
				{
					var c = shot[y * size.X + x];
					if (c.R > 200 && c.G < 50 && c.B > 200) magenta++;
					if (c.R + c.G + c.B > 0) nonBlack++;
					if (x < half && c != shot[y * size.X + x + half]) halvesDiffer++;
				}
			// in the stereo world pass the halves show different eyes
			var composeOk = magenta == 0 && nonBlack > 0 && (halvesDiffer == 0 || vrWorld);
			if (!composeOk) layerChecksFailed++;
			Log.Info($"[machost] compose check #{layerChecks} window={size.X}x{size.Y} fullscreen={game.Window.Fullscreen} magenta={magenta} nonBlack={nonBlack} of {shot.Length} halvesDiffer={halvesDiffer} ({(composeOk ? "ok" : "ERROR")})");
		}
	}

	next += delta;
	// behind (after a gap or a long frame, say): set to now, no catching up
	if (next < clock.Elapsed - delta)
		next = clock.Elapsed;

	var elapsedSecond = (clock.Elapsed - secondStart).TotalSeconds;
	if (elapsedSecond >= 1.0)
	{
		if (gpuPasses)
			GpuPassTimer.Report();
		var callbacks = VisionOSKit.CompletedTotal - callbacksAtSecondStart;
		Log.Info($"[machost] t={clock.Elapsed.TotalSeconds:F1}s ticks={ticks} updates={updates} updates/tick={(double)updates / ticks:F2} maxUpdates/tick={maxUpdatesPerTick} delta={delta.TotalMilliseconds:F3}ms fosterDelta={lastReportedDelta * 1000:F3}ms frame={game.Time.Frame} renderFrame={game.Time.RenderFrame} callbacks={(gpuTiming ? callbacks.ToString() : "-")}");
		secondStart = clock.Elapsed;
		ticks = 0; updates = 0; maxUpdatesPerTick = 0;
		callbacksAtSecondStart = VisionOSKit.CompletedTotal;
	}
}

Log.Info($"[machost] End: totalTicks={totalTicks} totalUpdates={totalUpdates} elapsed={clock.Elapsed.TotalSeconds:F2}s gameTime={game.Time.Elapsed.TotalSeconds:F2}s exiting={game.Exiting}" +
	(layerColor != null ? $" layerChecks={layerChecks} failed={layerChecksFailed}" : "") +
	(depthCheck > 0 ? $" depthChecks={depthChecks} failed={depthChecksFailed}" : "") +
	(vrWorld ? $" vrWorldFrames={vrWorldFrames} vrCanvasFrames={vrCanvasFrames} vrChecks={vrChecks} failed={vrChecksFailed} coarseAllocations={VisionOSKit.CoarseAllocations}{(vrWorldFrames > 0 && VisionOSKit.CoarseAllocations != 1 ? " (ERROR: exactly one allocation expected)" : "")}" : ""));

// Clean up in the order target, textures, native objects; Foster releases only its handles
VisionOSKit.Outputs = null;
VisionOSKit.AfterSceneRender = null;
VisionOSKit.AfterOutput = null;
VisionOSKit.AfterRender = null;
game.End();
depthMesh?.Dispose(); depthWhite?.Dispose();
layer0?.Dispose(); layer1?.Dispose();
composeCheck?.Dispose(); previewLeft?.Dispose(); previewRight?.Dispose(); layerColor?.Dispose(); layerDepthTex?.Dispose();
if (extColorProps != 0) SDL_DestroyProperties(extColorProps);
if (extDepthProps != 0) SDL_DestroyProperties(extDepthProps);
K6dMetal.k6d_metal_release(rateMapPtr);
K6dMetal.k6d_metal_release(mtlColor);
K6dMetal.k6d_metal_release(mtlDepth);
K6dMetal.k6d_metal_release(hostQueue);
K6dMetal.k6d_metal_release(hostDevice);
return 0;

// Preview composition: both layers side by side, scaled to the target size and centred
static void Compose(Batcher batcher, Texture left, Texture right, Point2 size)
{
	var scale = Math.Min(size.X / (float)(left.Width * 2), size.Y / (float)left.Height);
	var drawW = left.Width * scale; var drawH = left.Height * scale;
	var origin = new System.Numerics.Vector2((size.X - drawW * 2) / 2, (size.Y - drawH) / 2);
	batcher.PushSampler(new(TextureFilter.Nearest, TextureWrap.Clamp, TextureWrap.Clamp));
	batcher.Image(left, origin, System.Numerics.Vector2.Zero, System.Numerics.Vector2.One * scale, 0, Color.White);
	batcher.Image(right, origin + new System.Numerics.Vector2(drawW, 0), System.Numerics.Vector2.Zero, System.Numerics.Vector2.One * scale, 0, Color.White);
	batcher.PopSampler();
}

// Confirm key C as an SDL keyboard event (like the diagnostics patch, here from the host)
static unsafe void PushKey(bool down, SDL_Scancode scancode = SDL_Scancode.SDL_SCANCODE_C)
{
	var ev = default(SDL_Event);
	ev.key.type = down ? SDL_EventType.SDL_EVENT_KEY_DOWN : SDL_EventType.SDL_EVENT_KEY_UP;
	ev.key.timestamp = SDL_GetTicksNS();
	ev.key.scancode = scancode;
	ev.key.down = down;
	ev.key.repeat = false;
	SDL_PushEvent(ref ev);
}

/// <summary>
/// Performance: GPU time per command buffer through the kit's completion callback; the labels
/// arrive after every tick in commit order (two buffers per submission). Exclusive time of a
/// buffer = end minus max(start, end of the predecessor), because the queue executes serially
/// but the start is already set when enqueued; the inclusive time is end minus start.
/// </summary>
static unsafe class GpuPassTimer
{
	private static readonly object gate = new();
	private static readonly Queue<(string Label, bool World)> labels = new();
	private static readonly List<(double Start, double End)> completed = [];
	private static double previousEnd;
	private static readonly Dictionary<string, (double Incl, double Excl, int Count)> sums = [];
	private static int worldFrames, canvasFrames, unlabelled;
	private static double frameTotalSum; private static int frameTotalCount; private static double frameStart = -1, frameEnd;

	[UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
	public static void OnCompleted(nint userdata, nint commandBuffer)
	{
		if (K6dMetal.k6d_metal_command_buffer_times(commandBuffer, out var start, out var end) == 0)
			return;
		lock (gate)
			completed.Add((start, end));
	}

	public static void Expect(IEnumerable<string> frameLabels, bool world)
	{
		lock (gate)
		{
			foreach (var l in frameLabels) labels.Enqueue((l, world));
			if (world) worldFrames++; else canvasFrames++;
		}
	}

	/// <summary>Pairs completed buffers with labels and accumulates inclusive and exclusive times.</summary>
	private static void Drain()
	{
		lock (gate)
		{
			foreach (var (start, end) in completed)
			{
				if (end <= 0 || start <= 0) continue;
				var excl = end - Math.Max(start, previousEnd);
				if (excl < 0) excl = 0;
				previousEnd = Math.Max(previousEnd, end);
				string label; bool world = false;
				if (labels.Count > 0) { var e = labels.Dequeue(); label = e.Label; world = e.World; } else { label = "unlabelled"; unlabelled++; }
				var s = sums.GetValueOrDefault(label);
				sums[label] = (s.Incl + (end - start), s.Excl + excl, s.Count + 1);
				// total time of a world frame: from the first start (world) to the last end (rest)
				if (world)
				{
					if (label == "world" && frameStart < 0) frameStart = start;
					if (label == "rest") { frameEnd = end; if (frameStart >= 0) { frameTotalSum += frameEnd - frameStart; frameTotalCount++; } frameStart = -1; }
				}
			}
			completed.Clear();
		}
	}

	public static void Report()
	{
		Drain();
		lock (gate)
		{
			var wf = Math.Max(worldFrames, 1); var cf = Math.Max(canvasFrames, 1);
			string Part(string label) => sums.TryGetValue(label, out var s) ? $"{label}={s.Excl / (label == "canvas" ? cf : wf) * 1000:F3}/{s.Incl / (label == "canvas" ? cf : wf) * 1000:F3}" : $"{label}=-";
			var exclSum = 0.0;
			foreach (var l in new[] { "world", "edge", "sprites", "rest" }) if (sums.TryGetValue(l, out var s)) exclSum += s.Excl;
			Log.Info($"[machost] gpu passes (ms/frame exclusive/inclusive) {Part("world")} {Part("edge")} {Part("sprites")} {Part("rest")} {Part("canvas")} exclusiveSum={exclSum / wf * 1000:F3} frameSpan={(frameTotalCount > 0 ? frameTotalSum / frameTotalCount * 1000 : 0):F3} worldFrames={worldFrames} canvasFrames={canvasFrames} unlabelled={unlabelled} pending={labels.Count}");
			sums.Clear(); worldFrames = 0; canvasFrames = 0; unlabelled = 0; frameTotalSum = 0; frameTotalCount = 0;
		}
	}
}

/// <summary>Native helper native/k6d_metal.m (libk6dmetal.dylib next to the program).</summary>
static partial class K6dMetal
{
	[DllImport("k6dmetal")] public static extern int k6d_metal_command_buffer_times(nint commandBuffer, out double start, out double end);
	[DllImport("k6dmetal")] public static extern int k6d_metal_capture_start(nint device, [MarshalAs(UnmanagedType.LPStr)] string path);
	[DllImport("k6dmetal")] public static extern void k6d_metal_capture_stop();
	[DllImport("k6dmetal")] public static extern nint k6d_metal_device();
	[DllImport("k6dmetal")] public static extern nint k6d_metal_queue(nint device);
	[DllImport("k6dmetal")] public static extern nint k6d_metal_array_texture(nint device, uint width, uint height, uint layers, int kind);
	[DllImport("k6dmetal")] public static extern void k6d_metal_release(nint obj);
	// the host's rate map
	[DllImport("k6dmetal")] public static extern int k6d_metal_supports_rate_map(nint device, uint layers);
	[DllImport("k6dmetal")] public static extern nint k6d_metal_rate_map(nint device, uint screenWidth, uint screenHeight, uint layers, uint samples, float edgeQuality);
	[DllImport("k6dmetal")] public static extern int k6d_metal_rate_map_info(nint map, uint layer, out uint screenWidth, out uint screenHeight, out uint physicalWidth, out uint physicalHeight, out uint layerCount);
	[DllImport("k6dmetal")] public static extern void k6d_metal_rate_map_screen_to_physical(nint map, uint layer, float sx, float sy, out float px, out float py);
	[DllImport("k6dmetal")] public static extern void k6d_metal_rate_map_physical_to_screen(nint map, uint layer, float px, float py, out float sx, out float sy);
}

/// <summary>Field of the test quad in the layer texture.</summary>
static class QuadBox { public const int X = 40, Y = 560, Width = 200, Height = 120; }

/// <summary>Measurement image: bar positions as fractions of the logical size; the rows and columns
/// of the samples lie between the crossings.</summary>
static class RateMapBars
{
	public static readonly float[] VerticalFractions = [0.1f, 0.3f, 0.5f, 0.7f, 0.9f];
	public static readonly float[] HorizontalFractions = [0.15f, 0.5f, 0.85f];
	public static readonly float[] RowFractions = [0.3f, 0.65f, 0.95f];
	public static readonly float[] ColumnFractions = [0.2f, 0.6f, 0.8f];
}
