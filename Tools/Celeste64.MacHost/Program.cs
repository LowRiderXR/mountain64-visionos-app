// Celeste64.MacHost — Celeste 64 von aussen takten (K6c, F1) und in Ausgabeziele des Hosts
// rendern (K6d.1, F3). Vorbild für den Swift-Host auf visionOS: Game erzeugen, Begin(), dann
// Tick(delta) pro Frame der eigenen Uhr, End().
//
//   --hz N              Takt und Delta (90, 100, 120; Standard 90), delta = 1/N s
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
//   --test-quad         der Host zeichnet im selben Pass ein schwarzes Feld mit schrägem grünem
//                       Viereck; der Schichtvergleich zählt dort Kantenpixel mit Zwischenwerten
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
using System.Runtime.InteropServices;
using Celeste64;
using Foster.Framework;
using static SDL3.SDL;

int hz = 90;
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
long afterOutputCalls = 0;

for (int i = 0; i < args.Length; i++)
{
	switch (args[i])
	{
		case "--hz": hz = int.Parse(args[++i]); break;
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
		default: Console.Error.WriteLine($"Unbekanntes Argument: {args[i]}"); return 64;
	}
}
if (layers is not ("none" or "foster" or "external"))
{
	Console.Error.WriteLine($"--layers erwartet none, foster oder external, nicht '{layers}'");
	return 64;
}

Thread.CurrentThread.CurrentCulture = System.Globalization.CultureInfo.InvariantCulture;
if (gpuTiming)
	Environment.SetEnvironmentVariable("C64_GPU_TIMING", "1");

Log.Info($"[machost] hz={hz} seconds={seconds} gapMs={gapMs} present={!noPresent} gpuTiming={gpuTiming} layers={layers} layerDepth={layerDepth} kitSDL={GraphicsDevice.IsKitSDLLoaded()}");

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

var flags = VisionOSKit.Flags | (noPresent ? AppFlags.HiddenWindow : AppFlags.None);
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

var delta = TimeSpan.FromSeconds(1.0 / hz);
game.Begin();
Log.Info($"[machost] Begin fertig, Fenster {(noPresent ? "versteckt" : "sichtbar")}, Startzeit {game.Time.Elapsed.TotalMilliseconds:F1} ms, Fähigkeiten {game.GraphicsDevice.Capabilities}");

// ---- K6d.1: Ausgabeziel mit zwei Schichten ----
const int LayerW = 1280, LayerH = 720, LayerCount = 2;
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
			mtlColor = K6dMetal.k6d_metal_array_texture(hostDevice, LayerW, LayerH, LayerCount, 0);
			extColorProps = SDL_CreateProperties();
			SDL_SetPointerProperty(extColorProps, SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER, mtlColor);
			layerColor = new Texture(gd, LayerW, LayerH, TextureFormat.Color, LayerCount, TextureFlags.RenderTarget | TextureFlags.Sampled, extColorProps, "k6d-ext-color");
			if (layerDepth)
			{
				mtlDepth = K6dMetal.k6d_metal_array_texture(hostDevice, LayerW, LayerH, LayerCount, depthFormat == "d16" ? 1 : 2);
				extDepthProps = SDL_CreateProperties();
				SDL_SetPointerProperty(extDepthProps, SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER, mtlDepth);
				layerDepthTex = new Texture(gd, LayerW, LayerH, depthFormat == "d16" ? TextureFormat.Depth16 : TextureFormat.Depth32, LayerCount, TextureFlags.RenderTarget, extDepthProps, "k6d-ext-depth");
			}
		}

		Texture[] attachments = layerDepthTex != null ? [layerColor, layerDepthTex] : [layerColor];
		if (hostMsaa > 1)
		{
			// K6d.3: MSAA-Ziel über den vorhandenen Schichten, Auflösung in die Schichten
			var samples = hostMsaa switch { 2 => SampleCount.Two, 4 => SampleCount.Four, 8 => SampleCount.Eight, _ => throw new ArgumentException("--msaa erwartet 2, 4 oder 8") };
			var colorMemoryless = memoryless is "color" or "color+depth";
			var depthMemoryless = memoryless == "color+depth";
			layer0 = new Target(gd, attachments, 0, samples, multiSampleStore, DepthResolveFilter.Min, colorMemoryless, depthMemoryless, "k6d-layer0");
			layer1 = new Target(gd, attachments, 1, samples, multiSampleStore, DepthResolveFilter.Min, colorMemoryless, depthMemoryless, "k6d-layer1");
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
		VisionOSKit.Outputs = [layer0, layer1];
		VisionOSKit.AfterRender = () =>
		{
			var window = game.Window;
			// 1. Fenster vollständig schwarz, auch die Ränder neben der Vorschau
			window.Clear(Color.Black);
			// 2. Schicht 0 und 1 je in ihre eigene Vorschau-Textur (ein Blit = ganze Textur)
			layerColor.Blit(new RectInt(0, 0, LayerW, LayerH), 0, previewLeft, new RectInt(0, 0, LayerW, LayerH), 0, TextureFilter.Nearest);
			layerColor.Blit(new RectInt(0, 0, LayerW, LayerH), 1, previewRight, new RectInt(0, 0, LayerW, LayerH), 0, TextureFilter.Nearest);
			// 3. beide nebeneinander in einem Pass (LOAD nach dem Clear), skaliert auf das Fenster
			Compose(batcher, previewLeft, previewRight, window.SizeInPixels());
			batcher.Render(window);
			batcher.Clear();
		};
		if (testQuad)
		{
			// im selben Pass wie das Endbild: schwarzes Feld, darin ein schräges grünes Viereck,
			// als eigener Draw mit Tiefenschreiben (Tiefe 0 statt Clear 1), damit die aufgelöste
			// Tiefe verschiedene Werte hat; Fosters Batcher schreibt keine Tiefe
			var fill = new Color(0, 0, 255, 0);   // Batcher-Modus «Fill»: nur die Vertexfarbe
			var black = new Color(0, 0, 0, 255); var green = new Color(0, 255, 0, 255);
			float bx = QuadBox.X, by = QuadBox.Y, bw = QuadBox.Width, bh = QuadBox.Height;
			var quadMesh = new Mesh<BatcherVertex>(gd, name: "k6d-quad");
			quadMesh.SetVertices((ReadOnlySpan<BatcherVertex>)[
				new(new(bx, by), black, fill), new(new(bx + bw, by), black, fill), new(new(bx + bw, by + bh), black, fill), new(new(bx, by + bh), black, fill),
				new(new(bx + 30, by + 10), green, fill), new(new(bx + 170, by + 25), green, fill), new(new(bx + 150, by + 110), green, fill), new(new(bx + 10, by + 95), green, fill),
			]);
			quadMesh.SetIndices((ReadOnlySpan<int>)[0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]);
			VisionOSKit.AfterOutput = output =>
			{
				if (++afterOutputCalls == 1)
					Log.Info($"[machost] AfterOutput erstmals: output={output.GetType().Name} {output.WidthInPixels}x{output.HeightInPixels}");
				var material = gd.Defaults.BatchMaterial;
				material.Vertex.SetUniformBuffer(System.Numerics.Matrix4x4.CreateOrthographicOffCenter(0, output.WidthInPixels, output.HeightInPixels, 0, 0, float.MaxValue));
				gd.Draw(new DrawCommand(output, quadMesh, material) { DepthTestEnabled = true, DepthWriteEnabled = true, DepthCompare = DepthCompare.Always, CullMode = CullMode.None, BlendMode = BlendMode.Premultiply });
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

// K6d.2: Celestes Welt-Ziel beobachten (Rücklesen von Farbe und Tiefe)
Target? mainTarget = null;
VisionOSKit.AfterSceneRender = t => mainTarget = t;
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

	var frameBefore = game.Time.Frame;
	game.Tick(delta, present: !noPresent);

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
				var depth = new ushort[tw * th];
				mainTarget.Attachments[1].GetData<ushort>(depth, new RectInt(0, 0, tw, th));
				ushort dmin = ushort.MaxValue, dmax = 0; var distinct = new HashSet<ushort>(); long zero = 0, full = 0;
				foreach (var d in depth) { if (d < dmin) dmin = d; if (d > dmax) dmax = d; distinct.Add(d); if (d == 0) zero++; if (d == ushort.MaxValue) full++; }
				depthInfo = $"min={dmin} max={dmax} distinct={distinct.Count} zero={zero} full={full} sampler={(mainTarget.Attachments[1].SampleCount != SampleCount.One ? "resolve" : "1x")}";
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
			Log.Info($"[machost] target dump {path}");
		}
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
		if (diff != 0 || nonBlack0 == 0) layerChecksFailed++;
		Log.Info($"[machost] layers check #{layerChecks} frame={game.Time.Frame} diff={diff} of {pixels0.Length} nonBlack0={nonBlack0} nonBlack1={nonBlack1} ({(diff == 0 && nonBlack0 > 0 ? "ok" : "FEHLER")})");

		// Test-Viereck: im schwarzen Feld zählen, wie viele Pixel rein grün sind und wie viele
		// Zwischenwerte haben (nur mit MSAA > 0)
		if (testQuad)
		{
			int full = 0, partial = 0, other = 0;
			for (int y = QuadBox.Y; y < QuadBox.Y + QuadBox.Height; y++)
				for (int x = QuadBox.X; x < QuadBox.X + QuadBox.Width; x++)
				{
					var c = pixels0[y * LayerW + x];
					if (c.R == 0 && c.B == 0 && c.G == 255) full++;
					else if (c.R == 0 && c.B == 0 && c.G > 0) partial++;
					else if (!(c.R == 0 && c.G == 0 && c.B == 0)) other++;
				}
			Log.Info($"[machost] quad check #{layerChecks} msaa={hostMsaa} afterOutputCalls={afterOutputCalls} full={full} partial={partial} other={other} ({(hostMsaa > 1 ? (partial > 0 ? "ok" : "FEHLER") : (partial == 0 ? "ok" : "FEHLER"))})");
			if ((hostMsaa > 1) != (partial > 0)) layerChecksFailed++;
		}

		// externe Tiefe: nach der Auflösung muss sie beschrieben sein (nicht nur der Clear-Wert)
		if (layerDepthTex != null)
		{
			try
			{
				string info;
				if (layerDepthTex.Format == TextureFormat.Depth16)
				{
					var d = new ushort[LayerW * LayerH]; layerDepthTex.GetData<ushort>(d, rect, 0);
					var set = new HashSet<ushort>(d); info = $"d16 distinct={set.Count} min={d.Min()} max={d.Max()}";
				}
				else
				{
					var d = new float[LayerW * LayerH]; layerDepthTex.GetData<float>(d, rect, 0);
					var set = new HashSet<float>(d); info = $"d32 distinct={set.Count} min={d.Min():F4} max={d.Max():F4}";
				}
				Log.Info($"[machost] depth check #{layerChecks} layer0 {info}");
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
			var composeOk = magenta == 0 && nonBlack > 0 && halvesDiffer == 0;
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
		var callbacks = VisionOSKit.CompletedTotal - callbacksAtSecondStart;
		Log.Info($"[machost] t={clock.Elapsed.TotalSeconds:F1}s ticks={ticks} updates={updates} updates/tick={(double)updates / ticks:F2} maxUpdates/tick={maxUpdatesPerTick} delta={delta.TotalMilliseconds:F3}ms fosterDelta={lastReportedDelta * 1000:F3}ms frame={game.Time.Frame} renderFrame={game.Time.RenderFrame} callbacks={(gpuTiming ? callbacks.ToString() : "-")}");
		secondStart = clock.Elapsed;
		ticks = 0; updates = 0; maxUpdatesPerTick = 0;
		callbacksAtSecondStart = VisionOSKit.CompletedTotal;
	}
}

Log.Info($"[machost] End: totalTicks={totalTicks} totalUpdates={totalUpdates} elapsed={clock.Elapsed.TotalSeconds:F2}s gameTime={game.Time.Elapsed.TotalSeconds:F2}s exiting={game.Exiting}" +
	(layerColor != null ? $" layerChecks={layerChecks} failed={layerChecksFailed}" : ""));

// Aufräumen in der Reihenfolge Ziel, Texturen, native Objekte; Foster gibt nur seine Handles frei
VisionOSKit.Outputs = null;
VisionOSKit.AfterSceneRender = null;
VisionOSKit.AfterOutput = null;
VisionOSKit.AfterRender = null;
game.End();
layer0?.Dispose(); layer1?.Dispose();
composeCheck?.Dispose(); previewLeft?.Dispose(); previewRight?.Dispose(); layerColor?.Dispose(); layerDepthTex?.Dispose();
if (extColorProps != 0) SDL_DestroyProperties(extColorProps);
if (extDepthProps != 0) SDL_DestroyProperties(extDepthProps);
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
static unsafe void PushKey(bool down)
{
	var ev = default(SDL_Event);
	ev.key.type = down ? SDL_EventType.SDL_EVENT_KEY_DOWN : SDL_EventType.SDL_EVENT_KEY_UP;
	ev.key.timestamp = SDL_GetTicksNS();
	ev.key.scancode = SDL_Scancode.SDL_SCANCODE_C;
	ev.key.down = down;
	ev.key.repeat = false;
	SDL_PushEvent(ref ev);
}

/// <summary>Nativer Helfer native/k6d_metal.m (libk6dmetal.dylib neben dem Programm).</summary>
static partial class K6dMetal
{
	[DllImport("k6dmetal")] public static extern nint k6d_metal_device();
	[DllImport("k6dmetal")] public static extern nint k6d_metal_queue(nint device);
	[DllImport("k6dmetal")] public static extern nint k6d_metal_array_texture(nint device, uint width, uint height, uint layers, int kind);
	[DllImport("k6dmetal")] public static extern void k6d_metal_release(nint obj);
}

/// <summary>Feld des Test-Vierecks in der Schichttextur (K6d.3).</summary>
static class QuadBox { public const int X = 40, Y = 560, Width = 200, Height = 120; }
