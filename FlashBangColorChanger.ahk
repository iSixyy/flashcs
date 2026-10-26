#NoEnv
#Persistent
#SingleInstance Force
SetBatchLines, -1
; Sample absolute screen coordinates. The default CoordMode for Pixel is relative to the
; active window, which moves the sample grid whenever another window has focus.
CoordMode, Pixel, Screen
CoordMode, ToolTip, Screen

; =============================================================================
; FLASH DETECTION - HOW IT WORKS AND ITS LIMITS (v2.53 dynamic overlay)
; =============================================================================
; PixelGetColor only returns the final RGB colour of a pixel. It does NOT expose the
; alpha / opacity of CS2's flashbang effect, and nothing here reads game memory or
; touches the game process. What this script computes is an ESTIMATE of how "flashed"
; the image looks, built only from RGB samples:
;
;   1. A grid of SampleColumns x SampleRows points (cell centres) on the PRIMARY monitor.
;   2. For every sample:
;        luminance L = (0.2126*R + 0.7152*G + 0.0722*B) / 255         (0..1)
;        spread    S = (max(R,G,B) - min(R,G,B)) / 255                (0 = neutral grey/white)
;        bright    = clamp((L - BrightnessFloor) / (1 - BrightnessFloor))
;        neutral   = clamp(1 - S / (WhiteTolerance / 255))
;        score     = bright * neutral                                 (0..1)
;      A bright yellow or a blue sky gets a low score because it is not neutral.
;   3. Spatial coverage: the global level is the score that at least CoverageThreshold %
;      of the valid samples reach (a percentile). A small white area (HUD, a lamp, a
;      window in the map) cannot push the level up on its own.
;   4. raw intensity = clamp(level * IntensitySensitivity)
;   5. Persistence: a weak/medium raw value must repeat for ConfirmChecks consecutive
;      checks before it is used; a very strong one (>= FlashInstantLevel) is used at once.
;   6. Temporal smoothing: rises use an exponential filter (SmoothingAlpha per 50 ms),
;      falls are rate limited by FadingEvery, so the overlay fades instead of vanishing.
;   7. Overlay alpha (WinSet Transparent, 0 = invisible, 255 = opaque):
;        alpha = Transparency * ((I - IntensityThreshold) / (1 - IntensityThreshold)) ^ ResponseCurve
;      and 0 below IntensityThreshold. Transparency is the user's MAXIMUM, reached only
;      at full estimated intensity. The overlay colour (BkColor) is never altered.
;
; Known limits:
;   - This is not the physical opacity of the flash. A screen-filling white wall, a
;     loading screen or any neutral bright image can look like a flash. Tune
;     IntensitySensitivity / IntensityThreshold / BrightnessFloor / CoverageThreshold.
;   - TargetProcess (default cs2.exe) limits detection to when CS2 is the active window,
;     which removes false positives from other applications. Leave it empty to disable.
;   - Only the primary monitor is analysed and covered.
;   - The game must run in (borderless) windowed / fullscreen windowed mode; with
;     exclusive fullscreen PixelGetColor may read black and the overlay may not show.
;   - The overlay is a layered (semi-transparent) window. As documented for
;     PixelGetColor, such windows are normally not seen by it, so the overlay does not
;     darken its own samples (the original script relied on this too). If on some
;     system the overlay pulsed on and off by itself, that system is capturing it.
; =============================================================================

; Define path to settings file
IniFile := A_ScriptDir . "\settings.ini"
if !FileExist(IniFile) {
    IniWrite, }, %IniFile%, Settings, HotkeyToggle
    IniWrite, ., %IniFile%, Settings, HotkeyEyelids
    IniWrite, 200, %IniFile%, Settings, Transparency
    IniWrite, 50, %IniFile%, Settings, CheckInterval
    IniWrite, 10, %IniFile%, Settings, FadingEvery
    IniWrite, 0x000000, %IniFile%, Settings, BkColor
}


; --- Default Settings ---
IniRead, HotkeyToggle, %IniFile%, Settings, HotkeyToggle, }
IniRead, HotkeyEyelids, %IniFile%, Settings, HotkeyEyelids, .
IniRead, Transparency, %IniFile%, Settings, Transparency, 200
IniRead, CheckInterval, %IniFile%, Settings, CheckInterval, 50
IniRead, FadingEvery, %IniFile%, Settings, FadingEvery, 10
IniRead, BkColor, %IniFile%, Settings, BkColor, 0x000000, 
global Enabled := true
global EyelidsClosed := 0

global appVersion := "v2.53"
global AutoGuiW, EyelidColor, Bottom_OffsetX, Bottom_OffsetY, Bottom_Screen, Bottom_Win, DisplaySec
global FixedX, FixedY, FontColor, FontName, FontSize, FontStyle, GuiHeight, GuiPosition, GuiWidth
global SettingsGuiIsOpen, ShowModifierKeyCount, ShowMouseButton, ShowSingleModifierKey
global ShowStickyModKeyCount, Top_OffsetX, Top_OffsetY, Top_Screen, Top_Win, hGui_OSD, hGUI_s

; --- Flash detection settings (stored in settings.ini, defaults in SetFlashTuningDefaults) ---
global Transparency, CheckInterval, FadingEvery, BkColor
global IntensitySensitivity, IntensityThreshold, ResponseCurve, SmoothingAlpha
global WhiteTolerance, BrightnessFloor, CoverageThreshold, SampleColumns, SampleRows
global ConfirmChecks, TargetProcess, ShowDebug
global FlashInstantLevel := 0.8     ; raw intensity that skips the ConfirmChecks wait

; --- Flash detection state ---
; Only FlashDetectionTick writes FlashRaw/FlashTarget; only OverlayStep writes FlashSmoothed
; (ToggleEyelids/ResetFlashState also reset it from hotkeys). Both run as Critical threads.
global FlashRaw := 0.0, FlashTarget := 0.0, FlashSmoothed := 0.0, FlashConfirmCount := 0
global FlashCoverage := 0.0, FlashMeanScore := 0.0, FlashValidSamples := 0, FlashSampleMs := 0.0
global FlashLastStepTick := 0, AnimTimerOn := false
global OverlayHwnd := 0, OverlayVisible := false, OverlayAlpha := 0, OverlayColor := ""
global OverlayW := 0, OverlayH := 0
global SampleX := [], SampleY := []
global SampleGridW := 0, SampleGridH := 0, SampleGridCols := 0, SampleGridRows := 0

; Read saved settings or set defaults (missing keys keep the default value)
SetFlashTuningDefaults()
IniRead, IntensitySensitivity, %IniFile%, Settings, IntensitySensitivity, %IntensitySensitivity%
IniRead, IntensityThreshold, %IniFile%, Settings, IntensityThreshold, %IntensityThreshold%
IniRead, ResponseCurve, %IniFile%, Settings, ResponseCurve, %ResponseCurve%
IniRead, SmoothingAlpha, %IniFile%, Settings, SmoothingAlpha, %SmoothingAlpha%
IniRead, WhiteTolerance, %IniFile%, Settings, WhiteTolerance, %WhiteTolerance%
IniRead, BrightnessFloor, %IniFile%, Settings, BrightnessFloor, %BrightnessFloor%
IniRead, CoverageThreshold, %IniFile%, Settings, CoverageThreshold, %CoverageThreshold%
IniRead, SampleColumns, %IniFile%, Settings, SampleColumns, %SampleColumns%
IniRead, SampleRows, %IniFile%, Settings, SampleRows, %SampleRows%
IniRead, ConfirmChecks, %IniFile%, Settings, ConfirmChecks, %ConfirmChecks%
IniRead, TargetProcess, %IniFile%, Settings, TargetProcess, %TargetProcess%
IniRead, ShowDebug, %IniFile%, Settings, ShowDebug, %ShowDebug%
SanitizeSettings()



CreateTrayMenu()


CreateTrayMenu() {
	Menu, Tray, NoStandard
	Menu, Tray, Add, Settings, ShowSettingsGUI
	Menu, Tray, Add
	Menu, Tray, Add, Exit, _ExitApp
	Menu, Tray, Default, Settings
}

_ExitApp() {
    SaveSettings()
    ExitApp
}



sGuiAddTitleText(text) {
	Gui, s:Font, s16
	Gui, s:Add, Text, xm y+20, %text%
	Gui, s:Font, s12
}

ShowSettingsGUI() {
	global HotkeyToggle
	global HotkeyEyelids
	global Transparency
	global CheckInterval
	global FadingEvery
		global NewHotkey
		global FadingEveryN
		global TransNVal
		global CheckNVal
		global NewEyelidToggle
		global HotkeyEyelids
		global SensN
		global ThreshN
		
	SettingsGuiIsOpen := true

	Gui, s:Destroy
	Gui, s:+HWNDhGUI_s
	Gui, s:Font, s12

	Gui, s:Add, Button, x+82 yp+2 gResetDefaults, Reset to Defaults

	Gui, s:Add, Text, xm yp+34, ____________________________________
	Gui, s:Add, Text, xm yp+20, To start on boot, copy script to this folder:
	Gui, s:Add, Button, xm+73 yp+20 gOpenStartupFolder, Open Startup Folder
	Gui, s:Add, Text, xm yp+34, ____________________________________
	
	Gui, s:Add, Text, xm y+1, Enable/Disable script:
	Gui, s:Add, Hotkey, x+10 w100 vNewHotkey gHotkeyChanged, %HotkeyToggle%

	Gui, s:Add, Text, xm yp+28, ____________________________________

	Gui, s:Add, Text, xm y+1, Eyelid Key:
	Gui, s:Add, Hotkey, x+10 w100 vNewEyelidToggle gEyelidToggleChanged, %HotkeyEyelids%

	Gui, s:Add, Text, xm yp+28, ____________________________________

	Gui, s:Add, Text, xm y+1, Max opacity (reached at full flash):
	Gui, s:Add, Slider, xm+10 w300 vTransN Range50-255 ToolTip gUpdateTransVal, %Transparency%

	Gui, s:Add, Text, xm yp+25, ____________________________________

	Gui, s:Add, Text, xm y+1, Flash sensitivity (100 = normal):
	Gui, s:Add, Slider, xm+10 w300 vSensN Range25-400 ToolTip gUpdateSensitivity, % Round(IntensitySensitivity * 100)

	Gui, s:Add, Text, xm yp+25, ____________________________________

	Gui, s:Add, Text, xm y+1, Ignore flashes weaker than (percent):
	Gui, s:Add, Slider, xm+10 w300 vThreshN Range0-95 ToolTip gUpdateThreshold, % Round(IntensityThreshold * 100)

	Gui, s:Add, Text, xm yp+25, ____________________________________

	Gui, s:Add, Text, xm y+1, Increase this value only if you're losing FPS
	Gui, s:Add, Text, xm y+1, Check Every (milliseconds):
	Gui, s:Add, Slider, xm+10 w300 vCheckN Range1-500 ToolTip gUpdateCheckInterval, %CheckInterval%

	Gui, s:Add, Text, xm yp+25, ____________________________________

	Gui, s:Add, Text, xm y+1, Fading (How fast it disappears): 
	Gui, s:Add, Slider, xm+10 w300 vFadingEveryN Range5-200 ToolTip gUpdateFadingEvery, %FadingEvery%

	Gui, s:Add, Text, xm yp+25, ____________________________________

	Gui, s:Add, Button, xm+82 y+1 gChangeBkColor, Change Overlay Color

	Gui, s:Add, Text, xm yp+34, ____________________________________
	Gui, s:Add, Text, xm y+5, >-------- Created by Brian Vuksanovich --------<
	Gui, s:Add, Text, xm y+10, Report bugs by commenting on
	Gui, s:Add, Button, xm+220 yp-7 gOpenWebsite, this video
	Gui, s:Add, Text, xm+40 yp+40, and
	Gui, s:Add, Button, x+6 yp-7 gOpenSubscribe, Subscribe to my channel!





	if (GuiPosition = "Fixed Position")
		OSD_EnableDrag()
	Gui, s:Show,, Settings - FlashbangColorChanger



	_CheckValues:
		Loop, Parse, Bottom_OffsetX,Bottom_OffsetY,Top_OffsetX,Top_OffsetY,FixedX,FixedY
		{
			if (%A_LoopField% = "") {
				%A_LoopField% := 0
			}
		}
	return

	_AutoGuiW:
		; GuiControlGet, AutoGuiW, s:
		Gui, Submit, NoHide
		GuiControl, % "s:Enable" !AutoGuiW, GuiWidth
		GuiControl, % "s:Enable" !AutoGuiW, GuiWUD
		GuiControl, 1:+Redraw, HotkeyText
	return

	UpdateGuiPosition:
		Gui, Submit, NoHide
		if (NewHotkey != "") {
			Hotkey, %HotkeyToggle%, ToggleScript, Off  ; remove old hotkey
			HotkeyToggle := NewHotkey
			Hotkey, %HotkeyToggle%, ToggleScript, On   ; set new hotkey
		}

		if (GuiPosition = "Fixed Position")
			OSD_EnableDrag()
		else
			OSD_DisableDrag()
	return


	OpenWebsite:
		Run, https://www.youtube.com/watch?v=TJouE879EUQ
    return

	OpenSubscribe:
		Run, https://www.youtube.com/@brian-vuksanovich?sub_confirmation=1
    return
	
	UpdateTransVal:
		global TransNVal
		global TransN
		GuiControlGet, TransN
		GuiControl,, TransNVal, % TransN
		Transparency = %TransN%
		SaveSettings()
	return

	UpdateSensitivity:
		GuiControlGet, SensN
		IntensitySensitivity := SensN / 100.0
		SaveSettings()
	return

	UpdateThreshold:
		GuiControlGet, ThreshN
		IntensityThreshold := ThreshN / 100.0
		SaveSettings()
	return

	UpdateCheckInterval:
		global CheckNVal
		global CheckN
		GuiControlGet, CheckN
		GuiControl,, CheckNVal, % CheckN
		CheckInterval = %CheckN%
		RestartDetectionTimer()
		SaveSettings()
	return
	
	UpdateFadingEvery:
		global FadingEvery
		GuiControlGet, FadingEveryN
		FadingEvery := FadingEveryN
		SaveSettings()
	return

	ChangeBkColor:
		global BkColor
		newColor := BkColor
		if Select_Color(hGUI_s, newColor) {
			BkColor := newColor
			ApplyOverlayColor()
			SaveSettings()
		}
	return
	
	ChangeEyelidColor:
		newColor := EyelidColor
		if Select_Color(hGUI_s, newColor) {
			Gui, 1:Color, %newColor%
			EyelidColor := newColor
			SaveSettings()
		}
	return
	
	UpdateFontSize:
		GuiControlGet, FontSize
		Gui, 1:Font, s%FontSize%
		GuiControl, 1:Font, HotkeyText
	return
	
	
	
	; --- Hotkey Change Handler ---
	HotkeyChanged:
		Gui, s:Submit, NoHide  ; Capture the new hotkey entered by the user

		; Check if the entered hotkey is valid and handle it gracefully
		if (NewHotkey == "") {
			; If nothing entered, just skip
			return
		}

		; Try applying the new hotkey, but if it fails, just ignore it
		Try {
			; Unbind the old hotkey (if it exists)
			if (HotkeyToggle != "") {
				Hotkey, %HotkeyToggle%, ToggleScript, Off
			}

			; Bind the new hotkey
			Hotkey, %NewHotkey%, ToggleScript, On
			; If we reach here, it means the key was valid, so we update the hotkey
			HotkeyToggle := NewHotkey
		}
		Catch {
			; If an error occurs (e.g., invalid hotkey), just silently ignore it
		}

			; Focus on the Transparency slider (or any other control you choose)
			GuiControl, Focus, TransN  ; Move focus to the Transparency slider
		SaveSettings()
	return



	; --- Apply New Hotkey ---
	ApplyNewHotkey:
		Gui, s:Submit, NoHide  ; Submit the GUI input

			; Unbind the old hotkey
			if (HotkeyToggle != "") {
				Hotkey, %HotkeyToggle%, ToggleScript, Off
			}
			; Set the new hotkey
			HotkeyToggle := NewHotkey
			; Bind the new hotkey
			Hotkey, %HotkeyToggle%, ToggleScript, On
	return
	
	
	
	; --- EyelidToggleChanged Change Handler ---
		EyelidToggleChanged:
			global NewEyelidToggle
			global HotkeyEyelids
			Gui, s:Submit, NoHide  ; Capture the new hotkey entered by the user

			; Check if the entered hotkey is valid and handle it gracefully
			if (NewEyelidToggle == "") {
				; If nothing entered, just skip
				
				return
			}

			; Try applying the new hotkey, but if it fails, just ignore it
			Try {
				; Unbind the old hotkey (if it exists)
				if (HotkeyEyelids != "") {
					Hotkey, %HotkeyEyelids%, ToggleOverlay, Off
				}

				; Bind the new hotkey
				Hotkey, %NewEyelidToggle%, ToggleOverlay, On
				; If we reach here, it means the key was valid, so we update the hotkey
				HotkeyEyelids := NewEyelidToggle
			}
			Catch {
				; If an error occurs (e.g., invalid hotkey), just silently ignore it
			}

			; Focus on the Transparency slider (or any other control you choose)
			GuiControl, Focus, TransN  ; Move focus to the Transparency slider
		SaveSettings()
	return
	
		
	ResetDefaults:
		; Make sure the variables are global
		global HotkeyToggle, HotkeyEyelids, Transparency, CheckInterval, FadingEvery, BkColor
		
		; Unbind hotkeys
		Try Hotkey, %HotkeyToggle%, ToggleScript, Off
		Try Hotkey, %HotkeyEyelids%, ToggleOverlay, Off
		
		; Load them into your script variables again
		HotkeyToggle := "}"  ; Set the default value for HotkeyToggle
		HotkeyEyelids := "."  ; Set the default value for HotkeyEyelids
		Transparency := 200  ; Set the default value for Transparency
		CheckInterval := 50  ; Set the default value for CheckInterval
		FadingEvery := 10    ; Set the default value for FadingEvery
		BkColor := 0x000000  ; Set the default value for BkColor
		SetFlashTuningDefaults()  ; Flash detection settings
		
		; Update GUI controls with new values
		GuiControl,, NewHotkey, %HotkeyToggle%
		GuiControl,, NewEyelidToggle, %HotkeyEyelids%
		GuiControl,, TransN, %Transparency%
		GuiControl,, CheckN, %CheckInterval%
		GuiControl,, FadingEveryN, %FadingEvery%
		GuiControl,, SensN, % Round(IntensitySensitivity * 100)
		GuiControl,, ThreshN, % Round(IntensityThreshold * 100)
		GuiControl,, ColorInput, %BkColor%
		
		; Rebind hotkeys with default values
		Hotkey, %HotkeyToggle%, ToggleScript, On
		Hotkey, %HotkeyEyelids%, ToggleOverlay, On

		; Apply the restored interval and colour to the running detection/overlay
		RestartDetectionTimer()
		ApplyOverlayColor()
		
		; Save the reset settings to the INI file
		SaveSettings()

	return
	
}


WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
	static hCursor := DllCall("LoadCursor", "Uint", 0, "Int", 32646, "Ptr") ; SizeAll = 32646

	if (hwnd = hGui_OSD) {
		PostMessage, 0xA1, 2
		DllCall("SetCursor", "ptr", hCursor)
	}
}

WM_MOVE(wParam, lParam, msg, hwnd) {
	if (hwnd = hGui_OSD) && GetKeyState("LButton", "P")
	{
		GuiControl, s:, FixedX, % lParam << 48 >> 48
		GuiControl, s:, FixedY, % lParam << 32 >> 48
	}
}

OSD_EnableDrag() {
	OnMessage(0x0201, "WM_LBUTTONDOWN")
	OnMessage(0x0003, "WM_MOVE")
	Gui, 1:-E0x20
}

OSD_DisableDrag() {
	OnMessage(0x0201, "")
	OnMessage(0x0003, "")
	Gui, 1:+E0x20
}







;-------------------------------------------------------------------------------
Select_Color(hGui, ByRef Color) { ; using comdlg32.dll
;-------------------------------------------------------------------------------

    ; CHOOSECOLOR structure expects text color in BGR format
    BGR := convert_Color(Color)

    ; unused, but a valid pointer to the structure
    VarSetCapacity(CUSTOM, 64, 0)


    ;-----------------------------------
    ; CHOOSECOLOR structure
    ;-----------------------------------

    If (A_PtrSize = 8) { ; 64 bit
        VarSetCapacity(CHOOSECOLOR, 72, 0)
        NumPut(     72, CHOOSECOLOR,  0) ; StructSize
        NumPut(   hGui, CHOOSECOLOR,  8) ; hwndOwner
        NumPut(    BGR, CHOOSECOLOR, 24) ; bgrColor
        NumPut(&CUSTOM, CHOOSECOLOR, 32) ; lpCustColors
        NumPut(  0x103, CHOOSECOLOR, 40) ; Flags
    }

    Else { ; 32 bit
        VarSetCapacity(CHOOSECOLOR, 36, 0)
        NumPut(     36, CHOOSECOLOR,  0) ; StructSize
        NumPut(   hGui, CHOOSECOLOR,  4) ; hwndOwner
        NumPut(    BGR, CHOOSECOLOR, 12) ; bgrColor
        NumPut(&CUSTOM, CHOOSECOLOR, 16) ; lpCustColors
        NumPut(  0x103, CHOOSECOLOR, 20) ; Flags
    }


    ;-----------------------------------
    ; call ChooseColorA function
    ;-----------------------------------

    If Not DllCall("comdlg32\ChooseColorA", "UInt", &CHOOSECOLOR)
        Return, False


    ;-----------------------------------
    ; result to return
    ;-----------------------------------

    ; chosen color
    RGB := convert_Color(NumGet(CHOOSECOLOR, A_PtrSize = 8 ? 24 : 12, "UInt"))
    Color := SubStr("0x00000", 1, 10 - StrLen(RGB)) SubStr(RGB, 3)
    Return, True
}



;-------------------------------------------------------------------------------
convert_Color(Color) { ; convert RGB <--> BGR
;-------------------------------------------------------------------------------
    $_FormatInteger := A_FormatInteger
    SetFormat, Integer, Hex
    Result := (Color & 0xFF) << 16 | Color & 0xFF00 | (Color >> 16) & 0xFF
    SetFormat, Integer, % $_FormatInteger
    Return, Result
}



; Set initial hotkey
Hotkey, %HotkeyToggle%, ToggleScript, On
Hotkey, %HotkeyEyelids%, ToggleOverlay, On

; Save settings on any exit (this used to sit after the auto-execute "return" and never ran)
OnExit("OnScriptExit")

; --- Set Timer ---
RestartDetectionTimer()

return








; --- SETTINGS HELPERS ---

; Default values of the flash detection settings. Used at start-up (as IniRead defaults)
; and by "Reset to Defaults".
SetFlashTuningDefaults() {
    IntensitySensitivity := 1.0   ; multiplier on the estimated intensity
    IntensityThreshold := 0.25    ; below this estimated intensity the overlay stays hidden
    ResponseCurve := 1.5          ; >1 keeps partial flashes faint, 1 = linear
    SmoothingAlpha := 0.7         ; rise speed per 50 ms (0.05 slow .. 1 instant)
    WhiteTolerance := 96          ; max channel spread (0-255) still counted as white
    BrightnessFloor := 0.45       ; luminance (0-1) below which a sample scores 0
    CoverageThreshold := 70       ; percent of samples that must reach the level
    SampleColumns := 4            ; sample grid (cost = columns x rows PixelGetColor calls)
    SampleRows := 3
    ConfirmChecks := 2            ; consecutive checks needed for weak/medium flashes
    TargetProcess := "cs2.exe"    ; only detect while this exe is active ("" = any window)
    ShowDebug := 0                ; 1 = show live detection values in a tooltip
}

; Clamp a setting to a valid range; non-numeric values fall back to the default.
ClampSetting(value, lo, hi, def, isInteger := false) {
    value := Trim(value)
    if value is not number
        return def
    value := value < lo ? lo : value > hi ? hi : value
    return isInteger ? Round(value) : value + 0.0
}

SanitizeSettings() {
    Transparency := ClampSetting(Transparency, 50, 255, 200, true)
    CheckInterval := ClampSetting(CheckInterval, 1, 500, 50, true)
    FadingEvery := ClampSetting(FadingEvery, 5, 200, 10, true)
    IntensitySensitivity := ClampSetting(IntensitySensitivity, 0.25, 4.0, 1.0)
    IntensityThreshold := ClampSetting(IntensityThreshold, 0.0, 0.95, 0.25)
    ResponseCurve := ClampSetting(ResponseCurve, 0.3, 4.0, 1.5)
    SmoothingAlpha := ClampSetting(SmoothingAlpha, 0.05, 1.0, 0.7)
    WhiteTolerance := ClampSetting(WhiteTolerance, 8, 255, 96, true)
    BrightnessFloor := ClampSetting(BrightnessFloor, 0.0, 0.9, 0.45)
    CoverageThreshold := ClampSetting(CoverageThreshold, 10, 100, 70, true)
    SampleColumns := ClampSetting(SampleColumns, 1, 16, 4, true)
    SampleRows := ClampSetting(SampleRows, 1, 12, 3, true)
    ConfirmChecks := ClampSetting(ConfirmChecks, 1, 10, 2, true)
    ShowDebug := ClampSetting(ShowDebug, 0, 1, 0, true)
    TargetProcess := Trim(TargetProcess)
    if (TargetProcess = "ERROR")
        TargetProcess := ""
}

RestartDetectionTimer() {
    if (Enabled)
        SetTimer, CheckForColor, %CheckInterval%
    else
        SetTimer, CheckForColor, Off
}

Clamp01(v) {
    return v < 0 ? 0.0 : v > 1 ? 1.0 : v
}




; --- FUNCTIONS ---

; Detection timer (every CheckInterval ms): samples the screen and updates FlashTarget.
CheckForColor:
    FlashDetectionTick()
return

FlashDetectionTick() {
    Critical
    if (!Enabled)
        return

    if (TargetProcess != "" && !WinActive("ahk_exe " . TargetProcess)) {
        ; CS2 is not the active window: skip sampling (saves CPU, no false positives)
        raw := 0.0
        FlashCoverage := 0.0, FlashMeanScore := 0.0, FlashValidSamples := 0, FlashSampleMs := 0.0
    } else {
        raw := EstimateFlashIntensity()
    }
    FlashRaw := raw

    ; Persistence: weak/medium readings must repeat before they count, a strong one counts
    ; at once, and once the overlay is showing the target simply follows the measurement.
    if (raw >= IntensityThreshold) {
        if (FlashConfirmCount < 1000)
            FlashConfirmCount++
    } else {
        FlashConfirmCount := 0
    }
    confirmed := (raw >= FlashInstantLevel) || (FlashConfirmCount >= ConfirmChecks) || (FlashSmoothed > IntensityThreshold)
    FlashTarget := confirmed ? raw : 0.0

    if (FlashTarget > 0 || FlashSmoothed > 0 || EyelidsClosed)
        StartOverlayAnimation()

    if (ShowDebug)
        ShowDebugInfo()
}

; Rebuild the sample grid (cell centres) for the current resolution and grid size.
BuildSampleGrid() {
    SampleX := [], SampleY := []
    Loop, %SampleRows% {
        py := Round((A_Index - 0.5) * A_ScreenHeight / SampleRows)
        Loop, %SampleColumns% {
            SampleX.Push(Round((A_Index - 0.5) * A_ScreenWidth / SampleColumns))
            SampleY.Push(py)
        }
    }
    SampleGridW := A_ScreenWidth, SampleGridH := A_ScreenHeight
    SampleGridCols := SampleColumns, SampleGridRows := SampleRows
}

; Flash score of one RGB sample (0..1): bright AND neutral (close to white).
SampleFlashScore(c, lumFloor, tol) {
    r := (c >> 16) & 0xFF, g := (c >> 8) & 0xFF, b := c & 0xFF
    lum := (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
    spread := (Max(r, g, b) - Min(r, g, b)) / 255.0
    bright := Clamp01((lum - lumFloor) / (1.0 - lumFloor))
    neutral := Clamp01(1.0 - spread / tol)
    return bright * neutral
}

; Highest score reached by at least `coverage` (0..1) of the samples (sorts `scores`).
SpatialLevel(scores, coverage) {
    n := scores.Length()
    if (n = 0)
        return 0.0
    ; insertion sort, ascending (n is small)
    Loop, % n - 1 {
        i := A_Index + 1
        v := scores[i]
        j := i - 1
        while (j >= 1 && scores[j] > v) {
            scores[j + 1] := scores[j]
            j--
        }
        scores[j + 1] := v
    }
    need := Ceil(coverage * n)
    need := need < 1 ? 1 : need
    return scores[n - need + 1]
}

; Estimated flash intensity (0..1) of the current screen. Not the real flash opacity.
EstimateFlashIntensity() {
    if (A_ScreenWidth != SampleGridW || A_ScreenHeight != SampleGridH
        || SampleColumns != SampleGridCols || SampleRows != SampleGridRows)
        BuildSampleGrid()

    tol := WhiteTolerance / 255.0
    scores := []
    sum := 0.0, hits := 0
    DllCall("QueryPerformanceFrequency", "Int64*", qpf)
    DllCall("QueryPerformanceCounter", "Int64*", t0)
    Loop, % SampleX.Length() {
        PixelGetColor, c, % SampleX[A_Index], % SampleY[A_Index], RGB
        if ErrorLevel
            continue
        score := SampleFlashScore(c, BrightnessFloor, tol)
        scores.Push(score)
        sum += score
        if (score >= 0.5)
            hits++
    }
    DllCall("QueryPerformanceCounter", "Int64*", t1)
    FlashSampleMs := qpf ? (t1 - t0) * 1000.0 / qpf : 0.0

    n := scores.Length()
    FlashValidSamples := n
    if (n = 0) {
        FlashCoverage := 0.0, FlashMeanScore := 0.0
        return 0.0
    }
    FlashMeanScore := sum / n
    FlashCoverage := hits / n          ; share of clearly white samples (diagnostic)
    return Clamp01(SpatialLevel(scores, CoverageThreshold / 100.0) * IntensitySensitivity)
}

; Map an intensity (0..1) to a window alpha (0 = invisible .. Transparency = user maximum).
IntensityToAlpha(intensity) {
    i := Clamp01(intensity)
    if (i <= IntensityThreshold)
        return 0
    u := (i - IntensityThreshold) / (1.0 - IntensityThreshold)
    return Round(Transparency * (u ** ResponseCurve))
}

; Create the overlay window once and reuse it (it is only hidden/shown afterwards).
; Click-through (WS_EX_TRANSPARENT), never activated (WS_EX_NOACTIVATE), layered, topmost.
EnsureOverlay(color) {
    DetectHiddenWindows, On
    if (!OverlayHwnd || !WinExist("ahk_id " . OverlayHwnd)) {
        Gui, 1:New, +AlwaysOnTop +ToolWindow -Caption +E0x08080020 +LastFound -DPIScale +HwndOverlayHwnd, Overlay
        Gui, 1:Color, %color%
        OverlayColor := color
        OverlayVisible := false
        OverlayAlpha := 0
    } else if (color != OverlayColor) {
        Gui, 1:Color, %color%
        OverlayColor := color
    }
}

ApplyOverlayColor() {
    if (OverlayHwnd)
        EnsureOverlay(BkColor)
}

; Show or update the overlay for an estimated intensity (0..1). The colour is used as is;
; only the real window transparency changes with the intensity.
ShowOverlay(color := "Black", intensity := 1.0) {
    alpha := IntensityToAlpha(intensity)
    if (alpha < 2) {
        HideOverlay()
        return 0
    }
    EnsureOverlay(color)
    DetectHiddenWindows, On
    if (alpha != OverlayAlpha) {
        WinSet, Transparent, %alpha%, ahk_id %OverlayHwnd%
        OverlayAlpha := alpha
    }
    if (!OverlayVisible || OverlayW != A_ScreenWidth || OverlayH != A_ScreenHeight) {
        OverlayW := A_ScreenWidth, OverlayH := A_ScreenHeight
        ; NA = show without activating, so the game keeps focus (x1 kept from the original)
        Gui, 1:Show, NA x1 y0 w%OverlayW% h%OverlayH%
        OverlayVisible := true
    }
    return alpha
}

HideOverlay() {
    if (OverlayVisible)
        Gui, 1:Hide
    OverlayVisible := false
    OverlayAlpha := 0
}

StartOverlayAnimation() {
    if (!AnimTimerOn) {
        AnimTimerOn := true
        SetTimer, FadeOutOverlay, 15
        OverlayStep()      ; react now instead of waiting for the first timer tick
    }
}

StopOverlayAnimation() {
    SetTimer, FadeOutOverlay, Off
    AnimTimerOn := false
    FlashLastStepTick := 0
}

; Animation timer (~15 ms, only while the overlay is active). It never samples the screen:
; it moves FlashSmoothed toward FlashTarget, applies the eyelids and draws the overlay.
FadeOutOverlay:
    OverlayStep()
return

OverlayStep() {
    Critical
    now := A_TickCount
    dt := FlashLastStepTick ? now - FlashLastStepTick : 15
    FlashLastStepTick := now
    dt := dt < 1 ? 1 : dt > 250 ? 250 : dt

    if (!Enabled) {
        StopOverlayAnimation()
        HideOverlay()
        return
    }

    if (FlashTarget > FlashSmoothed) {
        ; rise: exponential smoothing, time-normalised to 50 ms
        k := 1.0 - (1.0 - SmoothingAlpha) ** (dt / 50.0)
        FlashSmoothed += (FlashTarget - FlashSmoothed) * k
    } else {
        ; fall: linear fade, full -> 0 in 3120/FadingEvery ms (312 ms at the default 10),
        ; never below what is still detected
        fadeMs := 3120.0 / FadingEvery
        FlashSmoothed := Max(FlashTarget, FlashSmoothed - dt / fadeMs)
    }
    if (FlashSmoothed < 0.002)
        FlashSmoothed := 0.0

    ; Manual eyelids have priority: full configured opacity while closed.
    ShowOverlay(BkColor, EyelidsClosed ? 1.0 : FlashSmoothed)

    if (!EyelidsClosed && FlashSmoothed = 0 && FlashTarget = 0)
        StopOverlayAnimation()
}

ShowDebugInfo() {
    ToolTip, % Format("raw {:.2f}  target {:.2f}  smooth {:.2f}  alpha {}  white {:.0f}%  mean {:.2f}  n {}  {:.1f} ms{}"
        , FlashRaw, FlashTarget, FlashSmoothed, OverlayAlpha, FlashCoverage * 100, FlashMeanScore
        , FlashValidSamples, FlashSampleMs, EyelidsClosed ? "  [eyelids]" : ""), 0, 0, 20
}

ResetFlashState() {
    EyelidsClosed := 0
    FlashRaw := 0.0, FlashTarget := 0.0, FlashSmoothed := 0.0, FlashConfirmCount := 0
    StopOverlayAnimation()
    HideOverlay()
    ToolTip,,,, 20
}




; --- Hotkey Close Eyelids ---
; Manual toggle, independent of detection: closed stays closed until pressed again.
; On reopening, the overlay fades out (or keeps following a flash that is still detected).

ToggleOverlay:
    ToggleEyelids()
return

ToggleEyelids() {
    Critical
    if (!Enabled)
        return
    EyelidsClosed := EyelidsClosed ? 0 : 1
    if (!EyelidsClosed)
        FlashSmoothed := 1.0
    StartOverlayAnimation()
}



; --- MENU HANDLERS ---

ToggleScript:
Enabled := !Enabled
    if (Enabled) {
        DllCall("ShowCursor", "Int", false)
        cursorHidden := true
    } else {
		DllCall("ShowCursor", "Int", true)
    }
ResetFlashState()        ; hides the overlay and stops the animation timer
RestartDetectionTimer()  ; detection timer only runs while enabled
return



OnScriptExit(ExitReason := "", ExitCode := 0) {
    SaveSettings()
    return 0
}

SaveSettings() {
    global IniFile, HotkeyToggle, HotkeyEyelids, Transparency, CheckInterval, FadingEvery, BkColor
    IniWrite, %HotkeyToggle%, %IniFile%, Settings, HotkeyToggle
    IniWrite, %HotkeyEyelids%, %IniFile%, Settings, HotkeyEyelids
    IniWrite, %Transparency%, %IniFile%, Settings, Transparency
    IniWrite, %CheckInterval%, %IniFile%, Settings, CheckInterval
    IniWrite, %FadingEvery%, %IniFile%, Settings, FadingEvery
    IniWrite, %BkColor%, %IniFile%, Settings, BkColor
    IniWrite, % Round(IntensitySensitivity, 2), %IniFile%, Settings, IntensitySensitivity
    IniWrite, % Round(IntensityThreshold, 2), %IniFile%, Settings, IntensityThreshold
    IniWrite, % Round(ResponseCurve, 2), %IniFile%, Settings, ResponseCurve
    IniWrite, % Round(SmoothingAlpha, 2), %IniFile%, Settings, SmoothingAlpha
    IniWrite, %WhiteTolerance%, %IniFile%, Settings, WhiteTolerance
    IniWrite, % Round(BrightnessFloor, 2), %IniFile%, Settings, BrightnessFloor
    IniWrite, %CoverageThreshold%, %IniFile%, Settings, CoverageThreshold
    IniWrite, %SampleColumns%, %IniFile%, Settings, SampleColumns
    IniWrite, %SampleRows%, %IniFile%, Settings, SampleRows
    IniWrite, %ConfirmChecks%, %IniFile%, Settings, ConfirmChecks
    IniWrite, %TargetProcess%, %IniFile%, Settings, TargetProcess
    IniWrite, %ShowDebug%, %IniFile%, Settings, ShowDebug
}

OpenStartupFolder:
    Run, shell:startup
return



ExitScript:
ExitApp
