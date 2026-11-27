package tileit

// Amber-on-black look (old monochrome terminal) and a tiny auto-layout for
// the toolbar. Contrast first: text is bright amber on black, the active
// choice is inverted (black on amber), and disabled controls stay readable in
// a dimmer amber instead of fading to grey.

import "core:strings"
import rl "vendor:raylib"

// Palette.
AMBER        :: rl.Color{255, 176, 0, 255}   // main text, active fill
AMBER_BRIGHT :: rl.Color{255, 208, 110, 255} // hover text
AMBER_MID    :: rl.Color{200, 130, 0, 255}   // borders, values
AMBER_DIM    :: rl.Color{175, 115, 0, 255}   // disabled text, faint outlines (≈4.8:1 on black)
AMBER_DARK   :: rl.Color{70, 46, 0, 255}     // disabled borders, faint lines
PANEL        :: rl.Color{14, 10, 4, 255}     // control and pane background
PANEL_HOVER  :: rl.Color{40, 27, 4, 255}
BLACK        :: rl.Color{0, 0, 0, 255}
WHITE        :: rl.Color{255, 255, 255, 255}

FONT_SIZE  :: 18
ROW_H      :: f32(32)

ui_font: rl.Font
ui_font_loaded: bool

@(private = "file")
col :: proc(c: rl.Color) -> i32 { return i32(rl.ColorToInt(c)) }

theme_apply :: proc() {
	// A crisp monospace system font if there is one; the built-in pixel font
	// otherwise. ASCII plus the few symbols the status line uses.
	codepoints: [dynamic]rune
	defer delete(codepoints)
	for r in rune(32) ..= 126 do append(&codepoints, r)
	append(&codepoints, '°', '×', '…', '→', '–')
	when ODIN_OS == .Windows {
		for name in ([]string{"C:/Windows/Fonts/CascadiaMono.ttf", "C:/Windows/Fonts/consolab.ttf", "C:/Windows/Fonts/consola.ttf"}) {
			if !rl.FileExists(strings.clone_to_cstring(name, context.temp_allocator)) do continue
			f := rl.LoadFontEx(strings.clone_to_cstring(name, context.temp_allocator), FONT_SIZE * 2, raw_data(codepoints), i32(len(codepoints)))
			if f.glyphCount > 0 {
				ui_font = f
				ui_font_loaded = true
				rl.SetTextureFilter(ui_font.texture, .BILINEAR)
				rl.GuiSetFont(ui_font)
				break
			}
		}
	}
	if !ui_font_loaded do ui_font = rl.GetFontDefault()

	S :: proc(p: rl.GuiControlProperty, v: i32) { rl.GuiSetStyle(.DEFAULT, i32(p), v) }
	D :: proc(p: rl.GuiDefaultProperty, v: i32) { rl.GuiSetStyle(.DEFAULT, i32(p), v) }
	S(.BORDER_COLOR_NORMAL, col(AMBER_MID))
	S(.BASE_COLOR_NORMAL, col(PANEL))
	S(.TEXT_COLOR_NORMAL, col(AMBER))
	S(.BORDER_COLOR_FOCUSED, col(AMBER_BRIGHT))
	S(.BASE_COLOR_FOCUSED, col(PANEL_HOVER))
	S(.TEXT_COLOR_FOCUSED, col(AMBER_BRIGHT))
	S(.BORDER_COLOR_PRESSED, col(AMBER))
	S(.BASE_COLOR_PRESSED, col(AMBER))
	S(.TEXT_COLOR_PRESSED, col(BLACK))
	S(.BORDER_COLOR_DISABLED, col(AMBER_DARK))
	S(.BASE_COLOR_DISABLED, col(BLACK))
	S(.TEXT_COLOR_DISABLED, col(AMBER_DIM))
	S(.BORDER_WIDTH, 1)
	D(.TEXT_SIZE, FONT_SIZE)
	D(.TEXT_SPACING, 0)
	D(.LINE_COLOR, col(AMBER_MID))
	D(.BACKGROUND_COLOR, col(BLACK))
	// Slider: a solid amber bar on black reads better than a thin handle.
	rl.GuiSetStyle(.SLIDER, i32(rl.GuiSliderProperty.SLIDER_WIDTH), 12)
	rl.GuiSetStyle(.TOGGLE, i32(rl.GuiToggleProperty.GROUP_PADDING), 3)
	rl.GuiSetStyle(.CHECKBOX, i32(rl.GuiCheckBoxProperty.CHECK_PADDING), 3)
}

theme_unload :: proc() {
	if ui_font_loaded do rl.UnloadFont(ui_font)
}

// ---------------------------------------------------------------------------
// Text

text_width :: proc(text: string, size: f32 = FONT_SIZE) -> f32 {
	return rl.MeasureTextEx(ui_font, strings.clone_to_cstring(text, context.temp_allocator), size, 0).x
}

draw_text :: proc(text: string, x, y: f32, size: f32 = FONT_SIZE, color := AMBER) {
	rl.DrawTextEx(ui_font, strings.clone_to_cstring(text, context.temp_allocator), {x, y}, size, 0, color)
}

draw_text_centred :: proc(text: string, cx, cy: f32, size: f32 = FONT_SIZE, color := AMBER) {
	w := text_width(text, size)
	draw_text(text, cx - w / 2, cy - size / 2, size, color)
}

// ---------------------------------------------------------------------------
// Toolbar layout: controls flow left to right in a row; each helper places
// itself at the cursor, measures its own label, and advances the cursor.

Row :: struct {
	x, y: f32,
}

GAP :: f32(10)

row_start :: proc(y: f32, tag: string) -> Row {
	draw_text(tag, 14, y + (ROW_H - 15) / 2, 15, AMBER_MID)
	return {x = 74, y = y}
}

row_space :: proc(r: ^Row, px: f32) { r.x += px }

row_button :: proc(r: ^Row, label: string, enabled := true) -> bool {
	w := text_width(label) + 28
	if !enabled do rl.GuiDisable()
	hit := rl.GuiButton({r.x, r.y, w, ROW_H}, strings.clone_to_cstring(label, context.temp_allocator))
	rl.GuiEnable()
	r.x += w + GAP
	return hit && enabled
}

// Exclusive choice; returns true when the selection changed.
row_choice :: proc(r: ^Row, labels: []string, active: ^i32, enabled := true) -> bool {
	w: f32 = 0
	for l in labels do w = max(w, text_width(l) + 24)
	before := active^
	if !enabled do rl.GuiDisable()
	joined := strings.join(labels, ";", context.temp_allocator)
	rl.GuiToggleGroup({r.x, r.y, w, ROW_H}, strings.clone_to_cstring(joined, context.temp_allocator), active)
	rl.GuiEnable()
	r.x += f32(len(labels)) * (w + 3) - 3 + GAP
	if !enabled do active^ = before
	return active^ != before
}

row_check :: proc(r: ^Row, label: string, value: ^bool, enabled := true) {
	box: f32 = 20
	if !enabled do rl.GuiDisable()
	rl.GuiCheckBox({r.x, r.y + (ROW_H - box) / 2, box, box}, strings.clone_to_cstring(label, context.temp_allocator), value)
	rl.GuiEnable()
	r.x += box + 8 + text_width(label) + GAP + 6
}

// Label on the left, bar, value on the right.
row_slider :: proc(r: ^Row, label, value_text: string, value: ^f32, lo, hi: f32, bar_w: f32 = 150, enabled := true) {
	lw := text_width(label)
	draw_text(label, r.x, r.y + (ROW_H - FONT_SIZE) / 2, FONT_SIZE, enabled ? AMBER : AMBER_DIM)
	x := r.x + lw + 10
	if !enabled do rl.GuiDisable()
	before := value^
	rl.GuiSliderBar({x, r.y + 7, bar_w, ROW_H - 14}, nil, nil, value, lo, hi) // filled bar: reads better than a handle
	rl.GuiEnable()
	if !enabled do value^ = before
	draw_text(value_text, x + bar_w + 8, r.y + (ROW_H - FONT_SIZE) / 2, FONT_SIZE, enabled ? AMBER_BRIGHT : AMBER_DIM)
	r.x = x + bar_w + 8 + max(text_width(value_text), text_width("0.00")) + GAP + 8
}

// Numeric entry: click (or Enter) to edit, type, Enter or click away to
// finish. The value only counts once editing ends; returns true then, so the
// caller can apply it without re-running on every keystroke.
row_value :: proc(r: ^Row, label: string, value: ^i32, lo, hi: i32, editing: ^bool, w: f32 = 120, enabled := true) -> (committed: bool) {
	draw_text(label, r.x, r.y + (ROW_H - FONT_SIZE) / 2, FONT_SIZE, enabled ? AMBER : AMBER_DIM)
	x := r.x + text_width(label) + 10
	if !enabled {
		rl.GuiDisable()
		editing^ = false
	}
	if rl.GuiValueBox({x, r.y, w, ROW_H}, nil, value, lo, hi, editing^) != 0 {
		if editing^ do committed = true
		editing^ = !editing^ && enabled
	}
	rl.GuiEnable()
	r.x = x + w + GAP
	return
}

row_label :: proc(r: ^Row, text: string, color := AMBER_MID) {
	draw_text(text, r.x, r.y + (ROW_H - FONT_SIZE) / 2, FONT_SIZE, color)
	r.x += text_width(text) + GAP
}
