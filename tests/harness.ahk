; Test harness: includes the real script (its auto-execute part is skipped because the
; #Include sits after ExitApp) and drives its real functions, timers and overlay window.
#NoEnv
#SingleInstance Force
SetBatchLines -1
CoordMode, Pixel, Screen
global IMG := A_ScriptDir "\img\"
global LogText := "", Fails := 0, Passes := 0, PicCtl, CurScene := ""
SoakSeconds := A_Args[1] ? A_Args[1] : 30
Mode := A_Args[2] ? A_Args[2] : "native"

; --- state normally initialised by the main auto-execute section ---
Enabled := true, EyelidsClosed := 0
Transparency := 200, CheckInterval := 50, FadingEvery := 10, BkColor := "0x000000"
SetFlashTuningDefaults()
TargetProcess := "", ShowDebug := 0
FlashInstantLevel := 0.8
ResetVars()

Gui, g:-Caption +HwndGameHwnd
Gui, g:Margin, 0, 0
Gui, g:Add, Picture, x0 y0 w%A_ScreenWidth% h%A_ScreenHeight% vPicCtl, % IMG "normal.bmp"
Gui, g:Show, x0 y0 w%A_ScreenWidth% h%A_ScreenHeight% NA
Sleep 300
EnsureOverlay(BkColor)
if (Mode = "win") {
    ; Under wine (no compositor) PixelGetColor DOES see the layered overlay. Shrink its
    ; region to 1 px so samples see the scene, as documented for Windows.
    WinSet, Region, 0-0 w1 h1, ahk_id %OverlayHwnd%
}
Log("== Mode: " Mode)

; ---------------- 1. static estimation ----------------
Log("== 1. Static estimation (grid " SampleColumns "x" SampleRows ", one call per scene)")
alphas := {}
list := ["normal","localized","hudstrip","yellow","sky","sandwall","sand_blend050","greywall","white"]
Loop, 21
    list.Push(Format("blend{:03}", (A_Index - 1) * 5))
for _, s in list {
    SetScene(s), Sleep(150)
    raw := EstimateFlashIntensity(), a := IntensityToAlpha(raw), alphas[s] := a
    Log(Format("  {:-14} raw {:.3f}  white {:3.0f}%  mean {:.3f}  n {}  alpha {:3} ({:3.0f}% of max)  {:.2f} ms"
        , s, raw, FlashCoverage * 100, FlashMeanScore, FlashValidSamples, a, a * 100 / Transparency, FlashSampleMs))
}
mono := true, prev := -1
Loop, 21 {
    a := alphas[Format("blend{:03}", (A_Index - 1) * 5)]
    if (a < prev)
        mono := false
    prev := a
}
Check("A  normal scene -> no overlay", alphas.normal = 0, alphas.normal)
Check("B  weak flash (60-70% white blend) -> faint overlay (0 < alpha <= 35% max)"
    , alphas.blend060 <= 0.35 * Transparency && alphas.blend070 > 0 && alphas.blend070 <= 0.35 * Transparency
    , alphas.blend060 "/" alphas.blend070)
Check("C  full flash -> exactly the configured maximum", alphas.white = Transparency && alphas.blend100 = Transparency, alphas.white)
Check("C  response monotonic with flash strength (blend 0..100%)", mono, "")
Check("C  partial flash (50%) far from full grey (alpha < 25% max)", alphas.blend050 < 0.25 * Transparency, alphas.blend050)
Check("D  localized white (12% of screen) -> no overlay", alphas.localized = 0, alphas.localized)
Check("F  white HUD strip (bottom 25%) -> no overlay", alphas.hudstrip = 0, alphas.hudstrip)
Check("   bright yellow screen -> no overlay", alphas.yellow = 0, alphas.yellow)
Check("   sky on top 40% -> no overlay", alphas.sky = 0, alphas.sky)

; ---------------- 2. temporal: flash, game fade, end ----------------
Log("== 2. Real timers: normal 1s, full flash 1.5s, game-side fade 100->0% over 2.1s, normal 1.5s")
ResetVars(), SetScene("normal")
SetTimer, CheckForColor, 50
tl := [["normal", 1000], ["white", 1500]]
p := 100
while (p >= 0) {
    tl.Push([Format("blend{:03}", p), 100]), p -= 5
}
tl.Push(["normal", 1500])
rec := RunTimeline(tl)
Log("  records: " rec.Length() " first t=" rec[1].t " a=" rec[1].a)
onsetT := "", maxDrop := 0, maxRiseInFade := 0, lastA := ""
fadeStart := 2500, fadeEnd := 4600
for _, r in rec {
    if (r.s = "white" && whiteT = "")
        whiteT := r.t - 50
    if (whiteT != "" && onsetT = "" && r.a >= 0.9 * Transparency)
        onsetT := r.t - whiteT
    if (r.t < 1000 && r.a > 0)
        earlyVisible := true
    if (lastA != "" && r.t > fadeStart) {
        maxDrop := Max(maxDrop, lastA - r.a)
        maxRiseInFade := Max(maxRiseInFade, r.a - lastA)
    }
    lastA := r.a
}
last := rec[rec.Length()]
Check("A  no overlay before the flash", !earlyVisible, "")
Check("C  full flash reaches >= 90% of max alpha within 250 ms", onsetT != "" && onsetT <= 250, onsetT " ms")
Check("E  fade has no abrupt step (max drop per 50 ms <= 70)", maxDrop <= 70, maxDrop)
Check("E  no flicker during fade (no rise > 5 while the flash fades)", maxRiseInFade <= 5, maxRiseInFade)
Check("E  overlay hidden and animation timer stopped after the flash", !last.vis && !AnimTimerOn && last.a = 0, "vis=" last.vis " anim=" AnimTimerOn)
DumpTimeline(rec, 100)

; ---------------- 3. sustained weak / localized ----------------
Log("== 3. Sustained scenes (1.5 s each, real timers)")
for _, s in ["blend060", "blend075", "localized", "hudstrip"] {
    ResetVars(), SetScene("normal"), Sleep(400)
    rec := RunTimeline([[s, 1500]])
    mx := 0
    for _, r in rec
        mx := Max(mx, r.a)
    Log(Format("  {:-10} final alpha {:3}  peak {:3}", s, rec[rec.Length()].a, mx))
    res%s% := mx
}
Check("B  sustained 60% flash stays faint (peak <= 35% max)", resblend060 <= 0.35 * Transparency, resblend060)
Check("B  sustained 75% flash visible but not full (0 < peak < max)", resblend075 > 0 && resblend075 < Transparency, resblend075)
Check("D  sustained localized white never shows overlay", reslocalized = 0, reslocalized)
Check("F  sustained white HUD strip never shows overlay", reshudstrip = 0, reshudstrip)

; ---------------- 4. eyelids ----------------
Log("== 4. Manual eyelids")
SetScene("normal"), ResetVars(), Sleep(300)
Hotkey_("ToggleOverlay")
Sleep(30)
a1 := OverlayAlpha
rec := RunTimeline([["normal", 1000]])
minA := 999
for _, r in rec
    minA := Min(minA, r.a)
Check("G  closing eyelids shows max opacity at once", a1 = Transparency, a1)
Check("G  detection does not reopen eyelids (1 s, no flash)", EyelidsClosed = 1 && minA = Transparency, "closed=" EyelidsClosed " minAlpha=" minA)
Hotkey_("ToggleOverlay")
rec := RunTimeline([["normal", 700]])
Check("G  reopening fades out (alpha 0 < a < max after ~100 ms)", rec[2].a > 0 && rec[2].a < Transparency, rec[2].a)
Check("G  reopening ends hidden with timers stopped", rec[rec.Length()].a = 0 && !OverlayVisible && !AnimTimerOn, St())
; eyelids closed during a flash, flash ends while closed
ResetVars(), SetScene("white"), Sleep(300)
Hotkey_("ToggleOverlay")
rec := RunTimeline([["normal", 800]])
Check("G  eyelids keep priority after the flash ends", EyelidsClosed = 1 && rec[rec.Length()].a = Transparency, rec[rec.Length()].a)
Hotkey_("ToggleOverlay")
rec := RunTimeline([["normal", 700]])
Check("G  reopen after flash -> fades to hidden", rec[rec.Length()].a = 0 && !AnimTimerOn, St())

; ---------------- 5. enable / disable ----------------
Log("== 5. Enable/disable hotkey")
ResetVars(), SetScene("white"), Sleep(400)
before := OverlayAlpha
Hotkey_("ToggleScript")
off1 := OverlayVisible, anim1 := AnimTimerOn
FlashRaw := -1
Sleep(500)
Check("H  overlay was visible before disabling", before >= 0.95 * Transparency, before)
Check("H  disabling hides overlay and stops animation timer", !off1 && !anim1 && !OverlayVisible, "")
Check("H  no sampling while disabled", FlashRaw = -1, FlashRaw)
Hotkey_("ToggleOverlay")
Sleep(100)
Check("H  eyelid key ignored while disabled", EyelidsClosed = 0 && !OverlayVisible, EyelidsClosed)
Hotkey_("ToggleScript")
Sleep(300)
Check("H  re-enabling resumes detection", Enabled && OverlayAlpha >= 0.9 * Transparency, OverlayAlpha)
SetScene("normal"), Sleep(800)

; ---------------- 6. soak ----------------
Log("== 6. Soak test " SoakSeconds " s (cycles: normal, flash, fade, localized, eyelids)")
DetectHiddenWindows, On
WinGet, w0, List, % "ahk_pid " DllCall("GetCurrentProcessId")
mem0 := PrivateBytes()
start := A_TickCount, cycles := 0, msSum := 0, msN := 0, msMax := 0
while (A_TickCount - start < SoakSeconds * 1000) {
    tl := [["normal", 500], ["white", 500], ["blend080", 150], ["blend050", 150], ["blend020", 150], ["normal", 300], ["localized", 400]]
    for _, ph in tl {
        SetScene(ph[1]), t := A_TickCount
        while (A_TickCount - t < ph[2]) {
            Sleep(50)
            if (FlashValidSamples) {
                msSum += FlashSampleMs, msN++, msMax := Max(msMax, FlashSampleMs)
            }
        }
    }
    Hotkey_("ToggleOverlay")
    Sleep(200)
    Hotkey_("ToggleOverlay")
    cycles++
}
SetScene("normal"), Sleep(800)
WinGet, w1, List, % "ahk_pid " DllCall("GetCurrentProcessId")
mem1 := PrivateBytes()
Log(Format("  cycles {}  windows before {} after {}  working set {:.1f} MB -> {:.1f} MB  sampling avg {:.2f} ms max {:.2f} ms ({} px/check)"
    , cycles, w0, w1, mem0 / 1048576, mem1 / 1048576, msN ? msSum / msN : 0, msMax, SampleX.Length()))
Check("I  no window accumulation", w1 = w0, w0 "->" w1)
Check("I  overlay hidden and animation stopped at rest", !OverlayVisible && !AnimTimerOn, St())
Check("I  memory stable (< 2 MB growth)", mem1 - mem0 < 2 * 1048576, Round((mem1 - mem0) / 1024) " KB")

SetTimer, CheckForColor, Off
Log(Format("== RESULT: {} passed, {} failed", Passes, Fails))
FileAppend, %LogText%, % A_ScriptDir "\results.txt"
ExitApp, % Fails ? 1 : 0

St() {
    return Format("a={} vis={} anim={} smooth={:.3f} target={:.3f} raw={:.3f} eyelids={}", OverlayAlpha, OverlayVisible, AnimTimerOn, FlashSmoothed, FlashTarget, FlashRaw, EyelidsClosed)
}

; ---------------- helpers ----------------
; Run a hotkey label in its own thread, like a real key press does.
Hotkey_(label) {
    SetTimer, %label%, -1
    Sleep, 20
}
ResetVars() {
    EyelidsClosed := 0
    FlashRaw := 0.0, FlashTarget := 0.0, FlashSmoothed := 0.0, FlashConfirmCount := 0
    FlashCoverage := 0.0, FlashMeanScore := 0.0, FlashValidSamples := 0, FlashSampleMs := 0.0
    if (AnimTimerOn)
        StopOverlayAnimation()
    FlashLastStepTick := 0, AnimTimerOn := false
    if (OverlayHwnd)
        HideOverlay()
    OverlayAlpha := 0
}
SetScene(name) {
    CurScene := name
    GuiControl, g:, PicCtl, % "*w" A_ScreenWidth " *h" A_ScreenHeight " " IMG name ".bmp"
}
Sleep(ms) {
    Sleep, %ms%
}
RunTimeline(tl) {
    rec := [], t0 := A_TickCount
    for _, ph in tl {
        SetScene(ph[1]), ps := A_TickCount
        while (A_TickCount - ps < ph[2]) {
            Sleep, 50
            rec.Push({t: A_TickCount - t0, s: ph[1], raw: FlashRaw, tg: FlashTarget, sm: FlashSmoothed, a: OverlayAlpha, vis: OverlayVisible, an: AnimTimerOn, cc: FlashConfirmCount})
        }
    }
    return rec
}
DumpTimeline(rec, every) {
    lastT := -every
    for _, r in rec {
        if (r.t - lastT >= every) {
            Log(Format("    t={:5} {:-9} raw {:.2f} target {:.2f} smooth {:.2f} alpha {:3} vis {} anim {} cc {}", r.t, r.s, r.raw, r.tg, r.sm, r.a, r.vis, r.an, r.cc))
            lastT := r.t
        }
    }
}
PrivateBytes() {
    VarSetCapacity(pmc, 80, 0), NumPut(80, pmc, 0, "UInt")
    DllCall("psapi\GetProcessMemoryInfo", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "Ptr", &pmc, "UInt", 80)
    return NumGet(pmc, 16, "UPtr")  ; WorkingSetSize
}
Log(s) {
    LogText .= s "`n"
    FileAppend, % s "`n", *
}
Check(name, ok, detail) {
    if (ok)
        Passes++
    else
        Fails++
    Log((ok ? "PASS " : "FAIL ") name (detail != "" ? "   [" detail "]" : ""))
}

#Include %A_ScriptDir%\..\FlashBangColorChanger.ahk
