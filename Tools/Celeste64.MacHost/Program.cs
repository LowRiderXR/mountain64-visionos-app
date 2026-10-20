// Celeste64.MacHost — Celeste 64 von aussen takten (K6c, F1). Vorbild für den Swift-Host auf
// visionOS: Game erzeugen, Begin(), dann Tick(delta) pro Frame der eigenen Uhr, End().
//
//   --hz N          Takt und Delta (90, 100, 120; Standard 90), delta = 1/N s
//   --seconds S     Laufzeit (Standard 30); 0 = bis Escape im Spiel
//   --gap-ms M      einmalige Lücke von M ms nach 5 s (Pause, kein Nachholen)
//   --no-present    Fenster versteckt, Tick ohne Present (Kommandos werden trotzdem abgeschickt)
//   --gpu-timing    Completion-Rückruf des Kits setzen (C64_GPU_TIMING=1), Callbacks zählen
//
// Pro Sekunde eine Zeile: Ticks, Updates, Updates pro Tick, Delta (gefordert und von Foster
// gemeldet), Callbacks.

using System.Diagnostics;
using Celeste64;
using Foster.Framework;

int hz = 90;
double seconds = 30;
double gapMs = 0;
bool noPresent = false;
bool gpuTiming = false;

for (int i = 0; i < args.Length; i++)
{
	switch (args[i])
	{
		case "--hz": hz = int.Parse(args[++i]); break;
		case "--seconds": seconds = double.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture); break;
		case "--gap-ms": gapMs = double.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture); break;
		case "--no-present": noPresent = true; break;
		case "--gpu-timing": gpuTiming = true; break;
		default: Console.Error.WriteLine($"Unbekanntes Argument: {args[i]}"); return 64;
	}
}

Thread.CurrentThread.CurrentCulture = System.Globalization.CultureInfo.InvariantCulture;
if (gpuTiming)
	Environment.SetEnvironmentVariable("C64_GPU_TIMING", "1");

Log.Info($"[machost] hz={hz} seconds={seconds} gapMs={gapMs} present={!noPresent} gpuTiming={gpuTiming} kitSDL={GraphicsDevice.IsKitSDLLoaded()}");

var kitProperties = VisionOSKit.CreateDeviceProperties();
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
	SDL3.SDL.SDL_DestroyProperties(kitProperties);

var delta = TimeSpan.FromSeconds(1.0 / hz);
game.Begin();
Log.Info($"[machost] Begin fertig, Fenster {(noPresent ? "versteckt" : "sichtbar")}, Startzeit {game.Time.Elapsed.TotalMilliseconds:F1} ms");

var clock = Stopwatch.StartNew();
var next = clock.Elapsed;
var secondStart = clock.Elapsed;
long ticks = 0, updates = 0, totalTicks = 0, totalUpdates = 0;
int maxUpdatesPerTick = 0;
long callbacksAtSecondStart = VisionOSKit.CompletedTotal;
bool gapDone = false;
double lastReportedDelta = 0;

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

	var frameBefore = game.Time.Frame;
	game.Tick(delta, present: !noPresent);
	var stepped = (int)(game.Time.Frame - frameBefore);
	ticks++; totalTicks++;
	updates += stepped; totalUpdates += stepped;
	maxUpdatesPerTick = Math.Max(maxUpdatesPerTick, stepped);
	lastReportedDelta = game.Time.Delta;

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

Log.Info($"[machost] End: totalTicks={totalTicks} totalUpdates={totalUpdates} elapsed={clock.Elapsed.TotalSeconds:F2}s gameTime={game.Time.Elapsed.TotalSeconds:F2}s exiting={game.Exiting}");
game.End();
return 0;
