// Celeste64.MacHost — Celeste 64 von aussen takten (K6c, F1) und in Ausgabeziele des Hosts
// rendern (K6d.1, F3). Vorbild für den Swift-Host auf visionOS: Game erzeugen, Begin(), dann
// Tick(delta) pro Frame der eigenen Uhr, End().
//
//   --hz N              Takt und Delta (90, 100, 120; Standard 90), delta = 1/N s
//   --jitter-ms J       M4b.4-N2: vor jedem Tick zufällig bis J ms schlafen (unruhige Wanduhr wie
//                       auf der Brille); das Delta bleibt das Raster 1/N, fosterDelta konstant
//   --seconds S         Laufzeit (Standard 30); 0 = bis Escape im Spiel
//   --gap-ms M          einmalige Lücke von M ms nach 5 s (Pause, kein Nachholen)
//   --no-present        Fenster versteckt, Tick ohne Present (Kommandos werden trotzdem abgeschickt)
//   --gpu-timing        Completion-Rückruf des Kits setzen (C64_GPU_TIMING=1), Callbacks zählen
//   --layers none|foster|external
//                       K6d.1: Endbild statt ins Fenster in ein Ziel mit zwei Schichten rendern,
//                       ein Pass pro Schicht. foster = Foster legt die 2D-Array-Textur an;
//                       external = eine vorhandene MTLTexture (type2DArray) aus dem nativen Helfer
//                       libk6dmetal.dylib, importiert über die SDL-Property (P3), Device und Queue
//                       des Hosts über P1. Beide Schichten werden nebeneinander im Fenster gezeigt.
//   --layer-check N     alle N Ticks beide Schichten zurücklesen und vergleichen (Standard 300)
//   --no-layer-depth    ohne Tiefen-Array (Standard: Farbe und Tiefe mit je zwei Schichten)
//   --layer-selftest    einmal die verbotenen 2D-Operationen auf dem Array versuchen (Download,
//                       Blit und Sampling ohne Schicht) und die Ausnahmen loggen
//   --windowed          Vollbild aus dem Spielstand wieder aufheben (Test im Fenster)
//   --tap-confirm T,T   an diesen Ticks die Bestätigungstaste (C) kurz drücken (SDL_PushEvent),
//                       zum Beispiel 120,240,360 für Titel, Overworld, Level 1
//   --target-check N    alle N Ticks Celestes 640x360-Welt-Ziel zurücklesen (Farbe und Tiefe):
//                       Magenta, nicht-schwarz, Tiefenstatistik (K6d.2)
//   --target-dump PFX   dabei die Farbe als PFX-<frame>.ppm schreiben (Vergleich MSAA an/aus)
//   --blit-selftest     zwei Blits nebeneinander in dieselbe Textur, zurücklesen, beide Hälften
//                       müssen stehen (K6d.2, Blit in ein Teilrechteck)
//   --msaa N            K6d.3: die Schichtziele mit N Samples; Foster legt die MSAA-Texturen an und
//                       löst in die vorhandenen Schichten auf (Farbe über resolve_texture, Tiefe
//                       über die Kit-Properties)
//   --memoryless M      none | color | color+depth: MSAA-Farbe (und Tiefe) nur im Kachelspeicher
//   --no-multisample-store
//                       Samples der Farbe nach dem Pass nicht behalten (nur RESOLVE); Pflicht für
//                       memoryless Farbe. Standard ist behalten (Entscheid 3): eine vergessene
//                       Einstellung kostet Leistung, nicht das Bild. memoryless Farbe ohne diesen
//                       Schalter ist der Negativtest (abgelehnt)
//   --depth-format F    d16 | d32 (Standard d32, wie die Drawable-Tiefe der Brille)
//   --views N           K6e.1: 1 = ein Pass pro Schicht (zwei Ziele), 2 = ein Pass auf beide
//                       Schichten (ein Ziel mit Target.ViewCount 2, Vertex Amplification)
//   --test-quad         der Host zeichnet im selben Pass ein schwarzes Feld mit schrägem grünem
//                       Viereck; der Schichtvergleich zählt dort Kantenpixel mit Zwischenwerten
//   --rate-map          K6e.2 (F5): eigene Zweischicht-Rate-Map des Hosts (gleiches Profil in allen
//                       Schichten und Achsen, 1,0 im ersten Drittel, 0,5 danach) jeden Frame ans
//                       Ziel (Target.SetRasterizationRateMap); Viewport, Scissor und Batcher laufen
//                       dann im logischen Raum der Map. Nur mit --layers external (Host-Device).
//                       Messbild in jedem (layer-check/2)-ten Tick: schwarzes Bild mit Balken an
//                       bekannten logischen Positionen, beide Schichten zurücklesen, Soll aus
//                       mapScreenToPhysicalCoordinates, Toleranz 1 px
//   --rate-map-scale F  logische Grösse der Map = F × Texturgrösse (Standard 1,4; physisch rund
//                       0,67 × logisch, passt in 1280×720). 2,0 ist der Negativtest: physisch
//                       grösser als die Textur, SDL lehnt den Pass ab, Foster wirft
//   --pass-selftest     K6f.3: Device im Debug-Modus (SDL_ASSERT=ignore), ein gewöhnlicher Pass,
//                       den SDL ablehnt (Tiefentextur mit 256 Schichten), muss eine Ausnahme mit
//                       Meldung geben; Gegenprobe mit gültigem Ziel
//   --minimize-at T,T   K6f.3: am ersten Tick das Fenster minimieren, am zweiten zurückholen;
//                       der Lauf muss ohne Ausnahme weitergehen
//   --key-probe N       K6f.4: vor Tick N ein F7-Tastenereignis einspeisen (SDL_PushEvent), zwei
//                       Ticks später loslassen; meldet, nach welchem Tick Foster die Taste als
//                       gedrückt bzw. losgelassen sieht (vor da3b23a N+1, nachher N)
//   --vr-depth          M4b.2: Reverse-Z-Pfad (VisionOSKit.ReverseZ, Near 0,1 m wie der Layer der
//                       Brille): Shader-Varianten ohne SV_Depth, Welt-Ziel Depth32, Clear 0,
//                       Vergleiche getauscht, Himmel 3 km
//   --test-projection   dazu die Testprojektion nach computeProjection (Metal RH, unendliche
//                       Far-Ebene, Tangenten links 1,732, rechts 1,0, oben 1,0, unten 1,192)
//   --vr-world          M4b.3a: Stereo-Weltpass. Celeste bekommt vor jedem Tick die externen
//                       Schichten als «Drawable» (VisionOSKit.BeginVRFrame: Farbe und Tiefe als
//                       2D-Array, Rate Map des Hosts falls --rate-map, Testprojektion je Auge:
//                       Auge 0 Tangenten 1,732/1,0/1,0/1,192, Auge 1 gespiegelt), ein Level
//                       schreibt seine Welt direkt hinein; Titel und Overworld laufen weiter über
//                       Outputs (K6e). Braucht --layers external --views 2; impliziert --vr-depth.
//                       Der Schichtvergleich verlangt dann keine gleichen Schichten mehr
//   --res WxH           interne Auflösung (VisionOSKit.InternalWidth/Height) und Umrissbreite auto
//   --layer-dump PFX    bei jedem Schichtvergleich beide Schichten (physischer Bereich) als
//                       PFX-L0-<frame>.rgba und PFX-L1-<frame>.rgba schreiben
//   --vr-check          bei jedem Schichtvergleich im Weltpass die Farbe der Drawable-Schicht 0
//                       gegen die Zwischenschicht A (VisionOSKit.Intermediate) vergleichen: nur
//                       Umrisspixel dürfen abweichen (unter 10 %); mit C64_STEREO_NEGATIVE=logical-uv
//                       und --rate-map muss der Anteil gross werden (Negativtest Map am Kantenpass)
//   --stereo-selftest   M4b.4: Rechenprobe ohne Bild (VisionOSKit.DebugProject): Spielkamera im
//                       Ursprung nach +Y, Augen ±0,032 m, symmetrische Projektion (Tangenten 1),
//                       1000 px: Punkt in 2 m ergibt Disparität 16 px (±10 %), Achsmarken vorne
//                       (mittig), rechts (x ≈ 750) und oben (y ≈ 250); linkes Auge sieht den
//                       Punkt rechts der Mitte
//   --layer-size WxH    Grösse der externen Schichten (Standard 1280x720; 2624x2560 wie das
//                       Drawable der M5 bei Qualität 1,0)
//   --gpu-passes        M4b Leistung: eigener Completion-Rückruf; je Command Buffer GPU-Start und
//                       -Ende, je Sekunde inklusive und exklusive Zeit je Pass (world, edge,
//                       sprites, rest, canvas) und die Summe pro Welt-Frame
//   --metal-capture PATH:TICK
//                       Metal-Aufnahme des Ticks TICK als .gputrace nach PATH (Prozess braucht
//                       METAL_CAPTURE_ENABLED=1), in Xcode öffnen
//   --depth-check N     alle N Ticks drei Testquads in 1, 5 und 30 m vor der Kamera (im Blickraum)
//                       in das Welt-Ziel zeichnen, die Tiefe zurücklesen: near/d muss den Abstand
//                       auf 1 % treffen; dazu die kleinste Tiefe des Bildes (Himmel: > 0, im
//                       Kuppelbereich) und die Zahl der Pixel auf dem Clear-Wert 0; der Himmel
//                       wird nur im Level bewertet (nach der letzten --tap-confirm-Taste plus
//                       300 Ticks), Frames einer Blende werden übersprungen
//
// Vorschau (K6d.1-Korrektur): Das Fenster wird in jedem Frame zuerst schwarz gecleart; jede
// Schicht wird in eine eigene 2D-Textur geblittet (ein Blit deckt sein Ziel ganz ab, denn
// Fosters Blit ist ein Pass mit DONT_CARE und cycle über die ganze Zieltextur) und beide
// Texturen werden in einem Batcher-Pass nebeneinander gezeichnet. Der Schichtvergleich
// baut dieselbe Komposition zusätzlich in ein Offscreen-Ziel in Fenstergrösse und liest sie
// zurück: kein Magenta, Hälften gleich, Ränder schwarz.
//
// Pro Sekunde eine Zeile: Ticks, Updates, Updates pro Tick, Delta (gefordert und von Foster
// gemeldet), Callbacks.

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
long keyProbeSeenDown = -1, keyProbeSeenUp = -1;
// M4b.2: Reverse-Z-Pfad, Testprojektion, Tiefenprüfung
bool vrDepth = false, testProjection = false;
int depthCheck = 0;
// M4b.3a: Stereo-Weltpass, interne Auflösung, Schicht-Dumps, Vergleich Drawable gegen A
bool vrWorld = false, vrCheck = false, stereoSelftest = false;
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
// K6e.2: Map des Hosts, ihre logische und physische Grösse, Messbild-Frame
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
		case "--vr-depth": vrDepth = true; break;
		case "--test-projection": testProjection = true; break;
		case "--depth-check": depthCheck = int.Parse(args[++i]); break;
		case "--vr-world": vrWorld = true; vrDepth = true; break;
		case "--vr-check": vrCheck = true; break;
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
		default: Console.Error.WriteLine($"Unbekanntes Argument: {args[i]}"); return 64;
	}
}
if (testProjection && !vrDepth)
{
	Console.Error.WriteLine("--test-projection braucht --vr-depth (die Projektion gilt nur auf dem Reverse-Z-Pfad)");
	return 64;
}
if (vrWorld && (layers != "external" || views != 2))
{
	Console.Error.WriteLine("--vr-world braucht --layers external --views 2");
	return 64;
}
if (resW > 0 && resH > 0)
{
	VisionOSKit.InternalWidth = resW;
	VisionOSKit.InternalHeight = resH;
	VisionOSKit.EdgeLineWidth = Math.Max(1, (int)MathF.Round(resH / 360f));
}
if (vrDepth)
{
	// vor dem Spiel: Welt-Ziel und Shader-Auswahl lesen den Schalter beim Erzeugen bzw. Laden
	VisionOSKit.ReverseZ = true;
	VisionOSKit.SetNearMeters(0.1);
	if (testProjection)
		VisionOSKit.ProjectionOverride = VisionOSKit.CreateProjectionFromTangents(1.732f, 1.0f, 1.0f, 1.192f);
}
if (layers is not ("none" or "foster" or "external"))
{
	Console.Error.WriteLine($"--layers erwartet none, foster oder external, nicht '{layers}'");
	return 64;
}

Thread.CurrentThread.CurrentCulture = System.Globalization.CultureInfo.InvariantCulture;
if (gpuTiming)
	Environment.SetEnvironmentVariable("C64_GPU_TIMING", "1");

Log.Info($"[machost] hz={hz} seconds={seconds} gapMs={gapMs} present={!noPresent} gpuTiming={gpuTiming} layers={layers} layerDepth={layerDepth} kitSDL={GraphicsDevice.IsKitSDLLoaded()} vrDepth={vrDepth} testProjection={testProjection} depthCheck={depthCheck}");

// Device-Properties: Completion-Rückruf (K6b.2) und, für den externen Weg, Device und Queue
// des Hosts (P1), wie sie auf der Brille der Layer-Renderer liefert.
var kitProperties = VisionOSKit.CreateDeviceProperties();
nint hostDevice = 0, hostQueue = 0;
if (layers == "external")
{
	hostDevice = K6dMetal.k6d_metal_device();
	hostQueue = K6dMetal.k6d_metal_queue(hostDevice);
	if (hostDevice == 0 || hostQueue == 0)
	{
		Log.Error("[machost] Metal-Device oder Queue des Hosts fehlt");
		return 1;
	}
	if (kitProperties == 0)
		kitProperties = SDL_CreateProperties();
	SDL_SetPointerProperty(kitProperties, SDL_PROP_GPU_DEVICE_CREATE_METAL_DEVICE_POINTER, hostDevice);
	SDL_SetPointerProperty(kitProperties, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_QUEUE_POINTER, hostQueue);
	Log.Info($"[machost] Host-Device 0x{hostDevice:x} und Queue 0x{hostQueue:x} als P1-Properties gesetzt");
}
unsafe
{
	if (gpuPasses)
	{
		// M4b Leistung: eigener Rückruf statt des Zählers aus VisionOSKit (überschreibt ihn)
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
	// K6f.3: SDLs Debugprüfungen am Passbeginn melden per SDL_assert_release und geben NULL
	// zurück; ohne diesen Hint zeigt SDL einen Dialog und der Lauf hängt. Der Hint muss über
	// SDL_SetHint gesetzt werden: Environment.SetEnvironmentVariable erreicht unter .NET auf
	// macOS die native Umgebung nicht (erster Versuch hing im Dialog). Debug-Modus des Devices
	// einschalten.
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
	UpdateMode: UpdateMode.FixedStep(60),   // wird im Host-Modus nicht benutzt, der Host hat die Uhr
	Flags: flags,
	GraphicsDeviceProperties: kitProperties
));
if (kitProperties != 0)
	SDL_DestroyProperties(kitProperties);

if (stereoSelftest)
{
	// M4b.4: Umrechnung Kopfpose → Celeste ohne Bild prüfen
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
	Log.Info($"[machost] stereo selftest: point 2 m ahead left=({fl.X:F1},{fl.Y:F1}) right=({fr.X:F1},{fr.Y:F1}) disparity={disparity:F2} px expected={expected:F2} ({(okDisp ? "ok" : "FEHLER")}); axes: right mark left-eye=({rl.X:F1},{rl.Y:F1}) up mark=({ul.X:F1},{ul.Y:F1}) ({(okAxes ? "ok" : "FEHLER")}); scale={s}");
	// with a yawed game camera (looking +X) the forward mark must stay centred
	var fy = VisionOSKit.DebugProject(cam, new Vec3(1, 0, 0), Matrix.Identity, proj, new Vec3(2 * s, 0, 0), W, H);
	var fyUp = VisionOSKit.DebugProject(cam, new Vec3(1, 0, 0), Matrix.Identity, proj, new Vec3(2 * s, 0, 1 * s), W, H);
	var okYaw = Math.Abs(fy.X - W / 2f) < 1 && Math.Abs(fy.Y - H / 2f) < 1 && Math.Abs(fyUp.Y - (H / 2f - H / 4f)) < 1;
	Log.Info($"[machost] stereo selftest: yawed camera (+X) forward=({fy.X:F1},{fy.Y:F1}) up=({fyUp.X:F1},{fyUp.Y:F1}) ({(okYaw ? "ok" : "FEHLER")})");
	if (!(okDisp && okAxes && okYaw)) return 2;
}

var delta = TimeSpan.FromSeconds(1.0 / hz);
game.Begin();
Log.Info($"[machost] Begin fertig, Fenster {(noPresent ? "versteckt" : "sichtbar")}, Startzeit {game.Time.Elapsed.TotalMilliseconds:F1} ms, Fähigkeiten {game.GraphicsDevice.Capabilities}");

// K6f.3: ein gewöhnlicher Pass, den SDL ablehnt, muss eine Ausnahme mit Meldung geben statt
// die Draws still zu verwerfen. Einfachster erreichbarer Fall: SDLs Debugprüfung «Cannot bind a
// depth texture with more than 255 layers!» (Tiefentextur mit 256 Schichten, 4x4). Gegenprobe:
// ein gültiges kleines Ziel ohne Ausnahme.
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
		Log.Error("[machost] pass selftest 'Tiefe mit 256 Schichten': KEINE Ausnahme (Draws still verworfen)");
	}
	catch (InvalidOperationException e)
	{
		Log.Info($"[machost] pass selftest 'Tiefe mit 256 Schichten': abgelehnt ({e.GetType().Name}: {e.Message})");
	}
	catch (Exception e)
	{
		Log.Error($"[machost] pass selftest 'Tiefe mit 256 Schichten': unerwartet {e.GetType().Name}: {e.Message}");
	}
	finally
	{
		bad?.Dispose(); bigColor?.Dispose(); bigDepth?.Dispose();
	}
	try
	{
		using var good = new Target(gd, 8, 8, "k6f-good-pass");
		good.Clear(Color.Black);
		Log.Info("[machost] pass selftest 'gültiges Ziel 8x8': ok (keine Ausnahme)");
	}
	catch (Exception e)
	{
		Log.Error($"[machost] pass selftest 'gültiges Ziel 8x8': FEHLER {e.GetType().Name}: {e.Message}");
	}
}

// ---- K6d.1: Ausgabeziel mit zwei Schichten ----
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
			// vorhandene MTLTexture des Hosts: Farbe lesbar (für die Vorschau-Blits), Tiefe nur Ziel
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
		var samples = hostMsaa switch { 1 => SampleCount.One, 2 => SampleCount.Two, 4 => SampleCount.Four, 8 => SampleCount.Eight, _ => throw new ArgumentException("--msaa erwartet 1, 2, 4 oder 8") };
		var colorMemoryless = memoryless is "color" or "color+depth";
		var depthMemoryless = memoryless == "color+depth";
		if (views == 2)
		{
			// K6e.1: ein Ziel über beiden Schichten, ein Pass rendert beide Views
			layer0 = new Target(gd, attachments, 0, samples, multiSampleStore, DepthResolveFilter.Min, colorMemoryless, depthMemoryless, viewCount: 2, name: "k6e-views");
			layer1 = null;
			Log.Info($"[machost] views=2 msaa={hostMsaa} memoryless={memoryless} multiSampleStore={multiSampleStore} depthFormat={depthFormat}: ein Ziel mit ViewCount {layer0.ViewCount} (Farbe {(layer0.ColorMemoryless ? "memoryless" : "privat")}, Tiefe {(layer0.DepthMemoryless ? "memoryless" : "privat")})");
		}
		else if (hostMsaa > 1)
		{
			// K6d.3: MSAA-Ziel über den vorhandenen Schichten, Auflösung in die Schichten
			layer0 = new Target(gd, attachments, 0, samples, multiSampleStore, DepthResolveFilter.Min, colorMemoryless, depthMemoryless, name: "k6d-layer0");
			layer1 = new Target(gd, attachments, 1, samples, multiSampleStore, DepthResolveFilter.Min, colorMemoryless, depthMemoryless, name: "k6d-layer1");
			Log.Info($"[machost] msaa={hostMsaa} memoryless={memoryless} multiSampleStore={multiSampleStore} depthFormat={depthFormat}: Ziele über den Schichten angelegt (Farbe {(layer0.ColorMemoryless ? "memoryless" : "privat")}, Tiefe {(layer0.DepthMemoryless ? "memoryless" : "privat")})");
		}
		else
		{
			layer0 = new Target(gd, attachments, 0, "k6d-layer0");
			layer1 = new Target(gd, attachments, 1, "k6d-layer1");
		}
		// eine 2D-Textur pro Schicht: jeder Blit deckt sein Ziel vollständig ab
		previewLeft = new Texture(gd, LayerW, LayerH, TextureFormat.Color, 1, TextureFlags.RenderTarget, 0, "k6d-preview-left");
		previewRight = new Texture(gd, LayerW, LayerH, TextureFormat.Color, 1, TextureFlags.RenderTarget, 0, "k6d-preview-right");
		batcher = new Batcher(gd, "k6d-preview");
		VisionOSKit.Outputs = layer1 != null ? [layer0, layer1] : [layer0];
		VisionOSKit.AfterRender = () =>
		{
			var window = game.Window;
			// 1. Fenster vollständig schwarz, auch die Ränder neben der Vorschau
			window.Clear(Color.Black);
			// 2. Schicht 0 und 1 je in ihre eigene Vorschau-Textur (ein Blit = ganze Textur).
			//    K6e.2: mit Map schreibt der Pass nur den physischen Bereich der Textur (auch der
			//    Clear); der Rest bleibt undefiniert und darf nicht in die Vorschau
			var src = rateMapPtr != 0 ? new RectInt(0, 0, (int)physW, (int)physH) : new RectInt(0, 0, LayerW, LayerH);
			layerColor.Blit(src, 0, previewLeft, new RectInt(0, 0, LayerW, LayerH), 0, TextureFilter.Nearest);
			layerColor.Blit(src, 1, previewRight, new RectInt(0, 0, LayerW, LayerH), 0, TextureFilter.Nearest);
			// 3. beide nebeneinander in einem Pass (LOAD nach dem Clear), skaliert auf das Fenster
			Compose(batcher, previewLeft, previewRight, window.SizeInPixels());
			batcher.Render(window);
			batcher.Clear();
		};
		// K6e.2: Rate Map des Hosts mit zwei Schichten; logisch = Skalierung × Texturgrösse
		Mesh<BatcherVertex>? barsMesh = null;
		if (rateMap)
		{
			if (layers != "external")
				throw new ArgumentException("--rate-map braucht --layers external (die Map entsteht auf dem Host-Device)");
			if (K6dMetal.k6d_metal_supports_rate_map(hostDevice, LayerCount) == 0)
				throw new NotSupportedException($"Das Gerät kann keine Rate Maps mit {LayerCount} Schichten");
			logicalW = (int)(LayerW * rateMapScale); logicalH = (int)(LayerH * rateMapScale);
			rateMapPtr = K6dMetal.k6d_metal_rate_map(hostDevice, (uint)logicalW, (uint)logicalH, LayerCount, 16, 0.5f);
			if (rateMapPtr == 0)
				throw new InvalidOperationException("Rate Map nicht erzeugt");
			uint sw = 0, sh = 0, lc = 0, pw1 = 0, ph1 = 0;
			K6dMetal.k6d_metal_rate_map_info(rateMapPtr, 0, out sw, out sh, out physW, out physH, out lc);
			K6dMetal.k6d_metal_rate_map_info(rateMapPtr, 1, out _, out _, out pw1, out ph1, out _);
			Log.Info($"[machost] rate map: screen={sw}x{sh} layers={lc} physical layer0={physW}x{physH} layer1={pw1}x{ph1} texture={LayerW}x{LayerH} fits={(physW <= LayerW && physH <= LayerH ? "ja" : "NEIN (Negativtest)")} Target vor dem Setzen: logical={layer0.LogicalSize} inPixels={((IDrawableTarget)layer0).WidthInPixels}x{((IDrawableTarget)layer0).HeightInPixels}");
			// Negativtests der Foster-Prüfungen (die Map selbst bleibt gültig)
			Selftest2("Map mit logischer Grösse 0", () => layer0.SetRasterizationRateMap(rateMapPtr, 0, 0));
			if (layer1 != null)
				Selftest2("Map auf Ziel mit Schicht 1", () => layer1.SetRasterizationRateMap(rateMapPtr, logicalW, logicalH));
			void Selftest2(string what, Action action)
			{
				try { action(); Log.Error($"[machost] selftest '{what}': KEINE Ausnahme (Fehler)"); }
				catch (Exception e) { Log.Info($"[machost] selftest '{what}': abgelehnt ({e.GetType().Name}: {e.Message})"); }
			}
			// Messbild: schwarzes Bild in logischer Grösse, fünf rote senkrechte und drei blaue
			// waagrechte Balken, je 6 logische Pixel breit, an bekannten logischen Positionen
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
			// im selben Pass wie das Endbild: schwarzes Feld, darin ein schräges grünes Viereck,
			// als eigener Draw mit Tiefenschreiben (Tiefe 0 statt Clear 1), damit die aufgelöste
			// Tiefe verschiedene Werte hat; Fosters Batcher schreibt keine Tiefe
			var fill = new Color(0, 0, 255, 0);   // Batcher-Modus «Fill»: nur die Vertexfarbe
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
					Log.Info($"[machost] AfterOutput erstmals: output={output.GetType().Name} {output.WidthInPixels}x{output.HeightInPixels} (logisch)");
				var material = gd.Defaults.BatchMaterial;
				// Projektion aus der Grösse «in Pixeln» des Ziels: mit Map die logische Grösse
				material.Vertex.SetUniformBuffer(System.Numerics.Matrix4x4.CreateOrthographicOffCenter(0, output.WidthInPixels, output.HeightInPixels, 0, 0, float.MaxValue));
				if (quadMesh != null)
					gd.Draw(new DrawCommand(output, quadMesh, material) { DepthTestEnabled = true, DepthWriteEnabled = true, DepthCompare = DepthCompare.Always, CullMode = CullMode.None, BlendMode = BlendMode.Premultiply });
				// Messbild nur im Messframe, über allem anderen
				if (barsMesh != null && measureThisFrame)
					gd.Draw(new DrawCommand(output, barsMesh, material) { DepthTestEnabled = false, DepthWriteEnabled = false, CullMode = CullMode.None, BlendMode = BlendMode.Premultiply });
			};
		}
		Log.Info($"[machost] layers={layers}: Ziel {LayerW}x{LayerH} mit {LayerCount} Schichten ({(layerDepthTex != null ? "Farbe und Tiefe" : "nur Farbe")}), ein Pass pro Schicht, Vorschau nebeneinander");

		if (layerSelftest)
		{
			// Was auf einem 2D-Array nicht geht, muss klar scheitern statt still falsch zu laufen
			var probe = new Color[LayerW * LayerH];
			Selftest("GetData ohne Schicht", () => layerColor.GetData<Color>(probe, new RectInt(0, 0, LayerW, LayerH)));
			Selftest("SetData ohne Schicht", () => layerColor.SetData<Color>(probe, new RectInt(0, 0, LayerW, LayerH)));
			Selftest("Blit ohne Schicht", () => layerColor.Blit(previewLeft, TextureFilter.Nearest));
			Selftest("Sampling als 2D", () => { batcher.Image(layerColor, Color.White); batcher.Render(game.Window); batcher.Clear(); });
			Selftest("Target mit Schicht 2 von 2", () => new Target(gd, attachments, 2));
			void Selftest(string what, Action action)
			{
				try { action(); Log.Error($"[machost] selftest '{what}': KEINE Ausnahme (Fehler)"); }
				catch (Exception e) { Log.Info($"[machost] selftest '{what}': abgelehnt ({e.GetType().Name}: {e.Message})"); }
				finally { batcher.Clear(); }   // ein abgelehnter Draw lässt den Batch sonst stehen
			}
		}
	}
	catch (Exception e) when (e is NotSupportedException or ArgumentException or InvalidOperationException)
	{
		// erwarteter Weg mit SDL 3.4.12 oder bei einer abgelehnten Kombination: klare Ausnahme,
		// der Rest läuft im Fenster
		Log.Warning($"[machost] layers={layers} nicht möglich, weiter mit dem Fenster: {e.GetType().Name}: {e.Message}");
		VisionOSKit.Outputs = null; VisionOSKit.AfterRender = null; VisionOSKit.AfterOutput = null;
		layerColor?.Dispose(); layerDepthTex?.Dispose();
		layerColor = null; layerDepthTex = null;
	}
}

// K6d.2: Blit in ein Teilrechteck darf den Rest der Zieltextur nicht verwerfen
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
	Log.Info($"[machost] blit selftest: left red={leftRed}/{W * H} right green={rightGreen}/{W * H} ({(ok ? "ok" : "FEHLER")})");
}

// K6d.2: Celestes Welt-Ziel beobachten (Rücklesen von Farbe und Tiefe).
// K6e.2: die Map jeden Frame ans Ausgabeziel setzen, bevor Celeste hineinzeichnet (auf der
// Brille kommt sie pro Drawable neu vom Compositor; hier ist es dieselbe, der Weg ist derselbe)
Target? mainTarget = null;
bool rateMapLogged = false;
// M4b.2: drei Testquads im Blickraum (x rechts, y oben, -z vorwärts) in 1, 5 und 30 m, gezeichnet
// mit Celestes Sprite-Material (auf dem Reverse-Z-Pfad die Variante ohne SV_Depth) und nur der
// Projektion als Matrix; Tiefenschreiben mit Always, damit der Messwert sicher von den Quads kommt
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
			Log.Info($"[machost] rate map gesetzt: Target.LogicalSize={layer0.LogicalSize} Bounds={layer0.Bounds} inPixels={((IDrawableTarget)layer0).WidthInPixels}x{((IDrawableTarget)layer0).HeightInPixels} map=0x{layer0.RasterizationRateMap:x}");
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
	// Echtzeit-Takt: bis zum nächsten Tick warten (Sleep grob, dann drehen)
	var now = clock.Elapsed;
	if (now < next)
	{
		var wait = next - now;
		if (wait > TimeSpan.FromMilliseconds(2))
			Thread.Sleep(wait - TimeSpan.FromMilliseconds(1));
		while (clock.Elapsed < next)
			Thread.SpinWait(64);
	}

	// einmalige Lücke: Pause, danach genau ein Tick, kein Nachholen
	if (gapMs > 0 && !gapDone && clock.Elapsed.TotalSeconds >= 5)
	{
		gapDone = true;
		Thread.Sleep(TimeSpan.FromMilliseconds(gapMs));
		next = clock.Elapsed;
		Log.Info($"[machost] gap {gapMs:F0} ms bei t={clock.Elapsed.TotalSeconds:F2} s, nächster Tick ohne Nachholen");
	}

	// --windowed: Celeste schaltet nach dem Laden gemäss Spielstand ins Vollbild; hier zurück
	// (höchstens einmal pro Sekunde, der Wechsel dauert auf macOS mehrere Ticks)
	if (windowed && game.Window.Fullscreen && (clock.Elapsed - lastWindowedFix).TotalSeconds >= 1.0)
	{
		game.Window.Fullscreen = false;
		lastWindowedFix = clock.Elapsed;
		Log.Info("[machost] Vollbild aufgehoben (--windowed)");
	}

	// Bestätigungstaste an festen Ticks: Druck in diesem Tick, Loslassen im nächsten
	foreach (var t in tapConfirm)
		if (totalTicks == t) { PushKey(true); pendingTaps.Add((totalTicks + 2, false)); }
	for (int i = pendingTaps.Count - 1; i >= 0; i--)
		if (pendingTaps[i].tick == totalTicks) { PushKey(pendingTaps[i].down); pendingTaps.RemoveAt(i); }
	// K6f.4: Tastensonde F7, Druck vor Tick N, Loslassen vor Tick N+2
	if (keyProbeAt >= 0 && totalTicks == keyProbeAt) PushKey(true, SDL_Scancode.SDL_SCANCODE_F7);
	if (keyProbeAt >= 0 && totalTicks == keyProbeAt + 2) PushKey(false, SDL_Scancode.SDL_SCANCODE_F7);

	// M4b.4-N2: unruhige Wanduhr simulieren; der Tick bekommt trotzdem das Raster-Delta
	if (jitterMs > 0)
		Thread.Sleep(TimeSpan.FromMilliseconds(jitterRng.NextDouble() * jitterMs));

	if (metalCapturePath != null && totalTicks == metalCaptureTick)
	{
		var ok = K6dMetal.k6d_metal_capture_start(hostDevice != 0 ? hostDevice : K6dMetal.k6d_metal_device(), metalCapturePath);
		Log.Info($"[machost] metal capture tick={totalTicks} path={metalCapturePath} started={ok}");
	}
	var frameBefore = game.Time.Frame;
	// K6f.3: Fenster minimieren und zurückholen (SDL-Fensterhandle über SDL_GetWindows, Foster
	// zeigt es nicht); ohne Swapchain-Bild darf kein Pass scheitern
	if (minimizeAt.Count >= 1 && totalTicks == minimizeAt[0])
	{
		var windows = SDL_GetWindows();
		if (windows.Length > 0) { SDL_MinimizeWindow(windows[0]); Log.Info($"[machost] Fenster minimiert bei Tick {totalTicks}"); }
	}
	if (minimizeAt.Count >= 2 && totalTicks == minimizeAt[1])
	{
		var windows = SDL_GetWindows();
		if (windows.Length > 0) { SDL_RestoreWindow(windows[0]); Log.Info($"[machost] Fenster zurückgeholt bei Tick {totalTicks}"); }
	}
	// K6e.2: Messframe (Balkenbild statt Celeste) in der Mitte zwischen zwei Schichtvergleichen
	measureThisFrame = rateMapPtr != 0 && layerCheck > 0 && (totalTicks + 1) % layerCheck == layerCheck / 2;
	depthCheckThisFrame = depthCheck > 0 && totalTicks > 0 && totalTicks % depthCheck == 0;
	sceneRenderedThisFrame = false;
	// M4b.3a: vor dem Tick das «Drawable» des Hosts an Celeste; nach dem Tick auswerten
	if (vrWorld && mtlColor != 0 && mtlDepth != 0)
	{
		var eye0 = VisionOSKit.CreateProjectionFromTangents(1.732f, 1.0f, 1.0f, 1.192f);
		var eye1 = VisionOSKit.CreateProjectionFromTangents(1.0f, 1.732f, 1.0f, 1.192f);
		var hasMap = rateMapPtr != 0;
		// M4b.4: eyes 0.064 m apart (left eye at -x), head at O, culling from the union of both eyes
		VisionOSKit.BeginVRFrame(game.GraphicsDevice, mtlColor, mtlDepth, LayerW, LayerH, LayerCount, colorSrgb: false,
			hasMap ? rateMapPtr : 0, hasMap ? logicalW : LayerW, hasMap ? logicalH : LayerH, hasMap ? (int)physW : LayerW, hasMap ? (int)physH : LayerH,
			eye0, eye1,
			Matrix.CreateTranslation(-StereoIpd / 2, 0, 0), Matrix.CreateTranslation(StereoIpd / 2, 0, 0), Matrix.Identity,
			VisionOSKit.UnionProjection(eye0, eye1), originReset: totalTicks == 0);
	}
	try
	{
		game.Tick(delta, present: !noPresent);
	}
	catch (InvalidOperationException e)
	{
		// ein abgelehnter Pass (zum Beispiel Map physisch grösser als die Textur) kommt als
		// klare Ausnahme aus Foster; der Lauf endet hier, der Text ist das Ergebnis
		Log.Error($"[machost] Tick abgebrochen: {e.GetType().Name}: {e.Message}");
		layerChecksFailed++;
		break;
	}
	// M4b.3a: Ergebnis des Weltpasses dieses Ticks
	if (vrWorld && VisionOSKit.Frame != null)
	{
		var (rendered, flushes) = VisionOSKit.EndVRFrame();
		if (rendered) { if (vrWorldFrames++ == 0) Log.Info($"[machost] vr world: first world frame at tick {totalTicks} (frame {game.Time.Frame}), flushes={flushes}"); }
		else vrCanvasFrames++;
		// M4b Leistung: Etiketten der Buffer dieses Ticks (je Abschicken Upload und Render)
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

	// K6e.2: Messbild auswerten, beide Schichten, Soll aus der Map
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
			// senkrechte rote Balken: Soll-x aus der Map, Ist aus drei physischen Zeilen
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
			// waagrechte blaue Balken: Soll-y aus der Map, Ist aus drei physischen Spalten
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
		Log.Info($"[machost] ratemap check frame={game.Time.Frame} logical={logicalW}x{logicalH} physical={physW}x{physH} samples={samples} missing={missing} maxDevPx={maxDev:F3} meanDevPx={(found > 0 ? sumDev / found : 0):F3} ({(ok ? "ok" : "FEHLER")})");
	}

	// M4b.2: Tiefe der Testquads zurücklesen (Depth32 des Reverse-Z-Pfads), near/d gegen den Abstand
	if (depthCheckThisFrame && mainTarget != null && mainTarget.Attachments.Length > 1)
	{
		depthChecks++;
		if (!sceneRenderedThisFrame)
		{
			// Blende (Perform oder Hold): Game.Render zeichnet die Szene nicht, das Welt-Ziel zeigt den
			// letzten Frame ohne Testquads; nicht bewertet
			Log.Info($"[machost] depth check frame={game.Time.Frame}: kein Szenenrender in diesem Frame (Blende), übersprungen");
			depthChecks--;
		}
		else if (!vrDepth || mainTarget.Attachments[1].Format != TextureFormat.Depth32)
		{
			Log.Warning($"[machost] depth check frame={game.Time.Frame}: braucht --vr-depth (Depth32), Format ist {mainTarget.Attachments[1].Format}");
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
				Log.Info($"[machost] depth point frame={game.Time.Frame} D={depthPointsMeters[p]:F1} m pixel=({px},{py}) d={d:E4} near/d={distance:F4} m dev={dev:F4}% ({(pointOk ? "ok" : "FEHLER")})");
			}
			float dmin = float.MaxValue, dmax = 0; long zero = 0;
			foreach (var v in depth) { if (v <= 0) { zero++; continue; } if (v < dmin) dmin = v; if (v > dmax) dmax = v; }
			// Himmel: Würfel mit halber Kante R und Z-Faktor 0,5, also Abstände R/2 bis R·1,5: Tiefe near/(1,5 R) bis near/(0,5 R)
			var skyLo = nearM / (VisionOSKit.SkyRadiusMeters * 1.5); var skyHi = nearM / (VisionOSKit.SkyRadiusMeters * 0.5);
			// im Level (Game hält seine Szenen privat): nach der letzten Bestätigungstaste plus
			// Ladezeit und Blende (120 Ticks), sonst Titel oder Overworld ohne Himmel
			var inWorld = tapConfirm.Count > 0 && totalTicks > tapConfirm[^1] + 300;
			var skyOk = !inWorld || (zero == 0 && dmin >= skyLo * 0.99 && dmin <= skyHi * 1.01);
			ok &= skyOk;
			Log.Info($"[machost] depth sky frame={game.Time.Frame} inWorld={inWorld} zero={zero} of {depth.Length} minDepth={(zero == depth.Length ? 0 : dmin):E4} (= {(dmin > 0 && dmin < float.MaxValue ? nearM / dmin : 0):F0} m) maxDepth={dmax:E4} (= {(dmax > 0 ? nearM / dmax : 0):F3} m) dome={skyLo:E3}..{skyHi:E3} ({(skyOk ? "ok" : "FEHLER")}{(inWorld ? "" : ", nur im Level bewertet")})");
			if (!ok) depthChecksFailed++;
		}
	}

	// Welt-Ziel zurücklesen: Farbe (Auflösungstextur) und Tiefe (bei MSAA die Auflösungstiefe)
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
					// M4b.2: Reverse-Z-Pfad mit Float-Tiefe
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
			catch (Exception e) { depthInfo = $"Fehler: {e.GetType().Name}: {e.Message}"; }
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
			// M4b.2: dazu RGBA roh (Zeilen von oben) für scripts/compare-canvas.py --width <Breite>
			var rawPath = $"{targetDump}-{game.Time.Frame}.rgba";
			var raw = new byte[tw * th * 4];
			for (int i = 0; i < color.Length; i++) { raw[i * 4] = color[i].R; raw[i * 4 + 1] = color[i].G; raw[i * 4 + 2] = color[i].B; raw[i * 4 + 3] = color[i].A; }
			File.WriteAllBytes(rawPath, raw);
			Log.Info($"[machost] target dump {path} und {rawPath} ({tw}x{th})");
		}
	}
	// K6f.4: nach welchem Tick sieht Foster die Sonde? (Zustand nach Tick totalTicks)
	if (keyProbeAt >= 0 && totalTicks >= keyProbeAt)
	{
		var down = game.Input.Keyboard.Down(Keys.F7);
		if (down && keyProbeSeenDown < 0) { keyProbeSeenDown = totalTicks; Log.Info($"[machost] key probe: F7 eingespeist vor Tick {keyProbeAt}, als gedrückt gesehen nach Tick {totalTicks} (Verzögerung {totalTicks - keyProbeAt})"); }
		if (!down && keyProbeSeenDown >= 0 && keyProbeSeenUp < 0) { keyProbeSeenUp = totalTicks; Log.Info($"[machost] key probe: F7 losgelassen vor Tick {keyProbeAt + 2}, als losgelassen gesehen nach Tick {totalTicks} (Verzögerung {totalTicks - keyProbeAt - 2})"); }
	}
	var stepped = (int)(game.Time.Frame - frameBefore);
	ticks++; totalTicks++;
	updates += stepped; totalUpdates += stepped;
	maxUpdatesPerTick = Math.Max(maxUpdatesPerTick, stepped);
	lastReportedDelta = game.Time.Delta;

	// Schichtvergleich: beide Schichten zurücklesen, Pixel zählen, die sich unterscheiden
	if (layerColor != null && pixels0 != null && pixels1 != null && layerCheck > 0 && totalTicks % layerCheck == 0)
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
		// im Stereo-Weltpass unterscheiden sich die Schichten (Projektion je Auge): nur Inhalt verlangt
		var layersOk = vrWorld ? (nonBlack0 > 0 && nonBlack1 > 0) : (diff == 0 && nonBlack0 > 0);
		if (!layersOk) layerChecksFailed++;
		Log.Info($"[machost] layers check #{layerChecks} frame={game.Time.Frame} diff={diff} of {pixels0.Length} nonBlack0={nonBlack0} nonBlack1={nonBlack1} ({(layersOk ? "ok" : "FEHLER")}{(vrWorld ? ", Weltpass: Schichten dürfen abweichen" : "")})");
		Log.Info($"[machost] frame stats: views={views} passes/frame={game.GraphicsDevice.RenderPassesLastFrame} draws/frame={game.GraphicsDevice.DrawCallsLastFrame}");

		// M4b.3a: beide Schichten (physischer Bereich) als RGBA roh für compare-canvas.py
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

		// M4b.3a: Drawable-Schicht 0 gegen die Zwischenschicht A (beide physisch): der Kantenpass
		// kopiert A und dunkelt nur Umrisspixel ab; mit falscher Abtastung (Negativtest) weicht
		// fast alles ab
		if (vrCheck && VisionOSKit.Intermediate is { } intermediate && vrWorldFrames > 0)
		{
			vrChecks++;
			var checkRect = rateMapPtr != 0 ? new RectInt(0, 0, (int)physW, (int)physH) : rect;
			var aPixels = new Color[checkRect.Width * checkRect.Height];
			var dPixels = new Color[checkRect.Width * checkRect.Height];
			intermediate.Attachments[0].GetData<Color>(aPixels, checkRect, 0);
			layerColor.GetData<Color>(dPixels, checkRect, 0);
			int differing = 0, outlined = 0;
			for (int i = 0; i < aPixels.Length; i++)
			{
				if (aPixels[i] == dPixels[i]) continue;
				differing++;
				// outline = the edge colour mixed in at 70 %: darker than the source in every channel
				if (dPixels[i].R <= aPixels[i].R && dPixels[i].G <= aPixels[i].G && dPixels[i].B <= aPixels[i].B) outlined++;
			}
			var fraction = differing / (double)aPixels.Length * 100;
			// sprites and transparent models are drawn into the drawable after the copy, so not every
			// differing pixel is darker; the fraction separates the cases (negative test: over 30 %)
			var vrOk = fraction < 10;
			if (!vrOk) vrChecksFailed++;
			Log.Info($"[machost] vr check #{vrChecks} frame={game.Time.Frame} region={checkRect.Width}x{checkRect.Height} differing={differing} ({fraction:F2}%) outlineLike={outlined} negative={(VisionOSKit.StereoNegativeLogicalUV ? 1 : 0)} ({(vrOk ? "ok" : "FEHLER")})");
		}

		// Test-Viereck: im schwarzen Feld zählen, wie viele Pixel rein grün sind und wie viele
		// Zwischenwerte haben (nur mit MSAA > 0)
		if (testQuad)
		{
			// Zählbereich: das Feld ist logisch gezeichnet; mit Map liegt sein Bild im physischen
			// Raum, also die Ecken über die Map abbilden
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
			Log.Info($"[machost] quad check #{layerChecks} msaa={hostMsaa} afterOutputCalls={afterOutputCalls} region={qx0},{qy0}-{qx1},{qy1}{(rateMapPtr != 0 ? " (physisch aus der Map)" : "")} full={full} partial={partial} other={other} ({(hostMsaa > 1 ? (partial > 0 ? "ok" : "FEHLER") : (partial == 0 ? "ok" : "FEHLER"))})");
			if ((hostMsaa > 1) != (partial > 0)) layerChecksFailed++;
		}

		// externe Tiefe: nach der Auflösung muss sie beschrieben sein (nicht nur der Clear-Wert)
		if (layerDepthTex != null)
		{
			try
			{
				// mit Map nur der physische Bereich (ausserhalb schreibt der Pass nichts)
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

		// Kompositionsprüfung: dieselbe Vorschau wie im Fenster in ein Offscreen-Ziel in
		// Fenstergrösse, zurücklesen, Magenta zählen, Hälften vergleichen, Ränder prüfen
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
			// im Stereo-Weltpass zeigen die Hälften verschiedene Augen
			var composeOk = magenta == 0 && nonBlack > 0 && (halvesDiffer == 0 || vrWorld);
			if (!composeOk) layerChecksFailed++;
			Log.Info($"[machost] compose check #{layerChecks} window={size.X}x{size.Y} fullscreen={game.Window.Fullscreen} magenta={magenta} nonBlack={nonBlack} of {shot.Length} halvesDiffer={halvesDiffer} ({(composeOk ? "ok" : "FEHLER")})");
		}
	}

	next += delta;
	// hinterher (etwa nach einer Lücke oder einem langen Frame): auf jetzt setzen, kein Nachholen
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
	(vrWorld ? $" vrWorldFrames={vrWorldFrames} vrCanvasFrames={vrCanvasFrames} vrChecks={vrChecks} failed={vrChecksFailed}" : ""));

// Aufräumen in der Reihenfolge Ziel, Texturen, native Objekte; Foster gibt nur seine Handles frei
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

// Vorschau-Komposition: beide Schichten nebeneinander, auf die Zielgrösse skaliert und zentriert
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

// Bestätigungstaste C als SDL-Tastaturereignis (wie der Diagnose-Patch, hier vom Host)
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
/// M4b Leistung: GPU-Zeit je Command Buffer über den Completion-Rückruf des Kits; die Etiketten
/// kommen nach jedem Tick in Commit-Reihenfolge (zwei Buffer je Abschicken). Exklusive Zeit eines
/// Buffers = Ende minus max(Start, Ende des Vorgängers), weil die Queue seriell ausführt, der
/// Start aber schon beim Einreihen gesetzt wird; die inklusive Zeit ist Ende minus Start.
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
				// Gesamtzeit eines Welt-Frames: vom ersten Start (world) bis zum letzten Ende (rest)
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

/// <summary>Nativer Helfer native/k6d_metal.m (libk6dmetal.dylib neben dem Programm).</summary>
static partial class K6dMetal
{
	[DllImport("k6dmetal")] public static extern int k6d_metal_command_buffer_times(nint commandBuffer, out double start, out double end);
	[DllImport("k6dmetal")] public static extern int k6d_metal_capture_start(nint device, [MarshalAs(UnmanagedType.LPStr)] string path);
	[DllImport("k6dmetal")] public static extern void k6d_metal_capture_stop();
	[DllImport("k6dmetal")] public static extern nint k6d_metal_device();
	[DllImport("k6dmetal")] public static extern nint k6d_metal_queue(nint device);
	[DllImport("k6dmetal")] public static extern nint k6d_metal_array_texture(nint device, uint width, uint height, uint layers, int kind);
	[DllImport("k6dmetal")] public static extern void k6d_metal_release(nint obj);
	// K6e.2: Rate Map des Hosts
	[DllImport("k6dmetal")] public static extern int k6d_metal_supports_rate_map(nint device, uint layers);
	[DllImport("k6dmetal")] public static extern nint k6d_metal_rate_map(nint device, uint screenWidth, uint screenHeight, uint layers, uint samples, float edgeQuality);
	[DllImport("k6dmetal")] public static extern int k6d_metal_rate_map_info(nint map, uint layer, out uint screenWidth, out uint screenHeight, out uint physicalWidth, out uint physicalHeight, out uint layerCount);
	[DllImport("k6dmetal")] public static extern void k6d_metal_rate_map_screen_to_physical(nint map, uint layer, float sx, float sy, out float px, out float py);
	[DllImport("k6dmetal")] public static extern void k6d_metal_rate_map_physical_to_screen(nint map, uint layer, float px, float py, out float sx, out float sy);
}

/// <summary>Feld des Test-Vierecks in der Schichttextur (K6d.3).</summary>
static class QuadBox { public const int X = 40, Y = 560, Width = 200, Height = 120; }

/// <summary>Messbild K6e.2: Balkenlagen als Anteile der logischen Grösse; Zeilen und Spalten der
/// Stichproben liegen zwischen den Kreuzungen.</summary>
static class RateMapBars
{
	public static readonly float[] VerticalFractions = [0.1f, 0.3f, 0.5f, 0.7f, 0.9f];
	public static readonly float[] HorizontalFractions = [0.15f, 0.5f, 0.85f];
	public static readonly float[] RowFractions = [0.3f, 0.65f, 0.95f];
	public static readonly float[] ColumnFractions = [0.2f, 0.6f, 0.8f];
}
