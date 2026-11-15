package main

import "unicode"

// Keyboard translates the key events ScreenLink sends (Mac-style: ⌘ arrives as Meta) into
// Windows keystrokes, so Mac habits keep working on the PC: ⌘C copies, ⌘Tab switches apps,
// ⌥← jumps a word, ⌃⌘Q locks the screen, and so on.
//
// Modifiers are "lazy": holding ⌘ or ⇧ alone sends nothing to Windows. The Windows modifiers a
// shortcut needs are pressed right before its key, and released when the iPhone releases the
// modifier. That lets one iPhone modifier stand for different Windows ones (⌘ is Ctrl for ⌘C
// but Alt for ⌘Tab) and avoids stray lone Alt/Win taps opening menus.

// Windows virtual-key codes used here.
const (
	vkBack     = 0x08
	vkTab      = 0x09
	vkReturn   = 0x0D
	vkEscape   = 0x1B
	vkSpace    = 0x20
	vkPrior    = 0x21
	vkNext     = 0x22
	vkEnd      = 0x23
	vkHome     = 0x24
	vkLeft     = 0x25
	vkUp       = 0x26
	vkRight    = 0x27
	vkDown     = 0x28
	vkSnapshot = 0x2C
	vkInsert   = 0x2D
	vkDelete   = 0x2E
	vkLWin     = 0x5B
	vkApps     = 0x5D
	vkF1       = 0x70
	vkF4       = 0x73
	vkF11      = 0x7A
	vkLShift   = 0xA0
	vkLControl = 0xA2
	vkLMenu    = 0xA4 // Alt
	vkCapital  = 0x14
	vkNumLock  = 0x90
	vkY        = 0x59
	vkD        = 0x44
	vkL        = 0x4C
	vkS        = 0x53
)

// X11 keysyms (the values VNC uses).
const (
	xkBackSpace = 0xff08
	xkTab       = 0xff09
	xkReturn    = 0xff0d
	xkEscape    = 0xff1b
	xkDelete    = 0xffff
	xkHome      = 0xff50
	xkLeft      = 0xff51
	xkUp        = 0xff52
	xkRight     = 0xff53
	xkDown      = 0xff54
	xkPageUp    = 0xff55
	xkPageDown  = 0xff56
	xkEnd       = 0xff57
	xkPrint     = 0xff61
	xkInsert    = 0xff63
	xkMenu      = 0xff67
	xkKPEnter   = 0xff8d
	xkF1        = 0xffbe
	xkF12       = 0xffc9
	xkShiftL    = 0xffe1
	xkShiftR    = 0xffe2
	xkControlL  = 0xffe3
	xkControlR  = 0xffe4
	xkCapsLock  = 0xffe5
	xkMetaL     = 0xffe7
	xkMetaR     = 0xffe8
	xkAltL      = 0xffe9
	xkAltR      = 0xffea
	xkSuperL    = 0xffeb
	xkSuperR    = 0xffec
	xkHyperL    = 0xffed
	xkNumLock   = 0xff7f
)

// Injector is what the keyboard drives: SendInput on Windows, a recorder in tests.
type Injector interface {
	Key(vk uint16, down bool)
	Unicode(r rune, down bool)
	// CharKey returns the virtual key for a character on the current layout, and whether
	// Shift is needed to type it.
	CharKey(r rune) (vk uint16, shift bool, ok bool)
}

type mods uint8

const (
	modShift mods = 1 << iota
	modCtrl
	modAlt
	modWin
)

var modVK = []struct {
	m  mods
	vk uint16
}{{modCtrl, vkLControl}, {modAlt, vkLMenu}, {modShift, vkLShift}, {modWin, vkLWin}}

// What was pressed for a keysym, so its release mirrors it.
type pressed struct {
	vk      uint16
	r       rune
	nothing bool // the shortcut was a complete tap already
}

type Keyboard struct {
	inj Injector

	// Modifiers the iPhone is holding.
	cmd, ctrl, alt, shift, win bool
	winUsed                    bool // Super was combined with another key since it went down

	held mods // Windows modifiers currently pressed by us
	keys map[uint32]pressed
}

func NewKeyboard(inj Injector) *Keyboard {
	return &Keyboard{inj: inj, keys: map[uint32]pressed{}}
}

// plain maps the iPhone's modifiers one to one (⌘ → Ctrl). Used for clicks and scrolling.
func (k *Keyboard) plain() mods {
	var m mods
	if k.shift {
		m |= modShift
	}
	if k.ctrl || k.cmd {
		m |= modCtrl
	}
	if k.alt {
		m |= modAlt
	}
	if k.win {
		m |= modWin
	}
	return m
}

func (k *Keyboard) sync(want mods) {
	for _, e := range modVK { // release first so Alt→Ctrl swaps don't overlap
		if k.held&e.m != 0 && want&e.m == 0 {
			k.inj.Key(e.vk, false)
			k.held &^= e.m
		}
	}
	for _, e := range modVK {
		if k.held&e.m == 0 && want&e.m != 0 {
			k.inj.Key(e.vk, true)
			k.held |= e.m
		}
	}
}

// SyncForPointer makes held modifiers match the iPhone before a click or scroll (⇧-click
// extends a selection, ⌘-click becomes Ctrl-click).
func (k *Keyboard) SyncForPointer() {
	if k.win {
		k.winUsed = true
	}
	k.sync(k.plain())
}

func (k *Keyboard) tap(m mods, vk uint16) {
	k.sync(m)
	k.inj.Key(vk, true)
	k.inj.Key(vk, false)
}

// ReleaseAll lets go of everything (used when a viewer disconnects).
func (k *Keyboard) ReleaseAll() {
	for sym, p := range k.keys {
		k.release(p)
		delete(k.keys, sym)
	}
	k.cmd, k.ctrl, k.alt, k.shift, k.win = false, false, false, false, false
	k.sync(0)
}

func (k *Keyboard) release(p pressed) {
	switch {
	case p.nothing:
	case p.r != 0:
		k.inj.Unicode(p.r, false)
	default:
		k.inj.Key(p.vk, false)
	}
}

func (k *Keyboard) Event(sym uint32, down bool) {
	switch sym {
	case xkMetaL, xkMetaR:
		k.cmd = down
	case xkControlL, xkControlR:
		k.ctrl = down
	case xkAltL, xkAltR:
		k.alt = down
	case xkShiftL, xkShiftR:
		k.shift = down
	case xkSuperL, xkSuperR, xkHyperL:
		if down {
			k.win, k.winUsed = true, false
		} else {
			k.win = false
			if !k.winUsed { // the Windows key on its own opens Start
				k.sync(0)
				k.tap(0, vkLWin)
			}
		}
	default:
		if down {
			k.press(sym)
		} else if p, ok := k.keys[sym]; ok {
			k.release(p)
			delete(k.keys, sym)
		}
		return
	}
	if !down {
		// A modifier was let go: drop the Windows modifiers it was holding.
		k.sync(k.held & k.plain())
	}
}

func (k *Keyboard) press(sym uint32) {
	if k.win {
		k.winUsed = true
	}
	shiftM := mods(0)
	if k.shift {
		shiftM = modShift
	}
	r := keysymRune(sym)
	lower := unicode.ToLower(r)

	// Mac shortcuts with a different Windows equivalent.
	if k.cmd && !k.ctrl && !k.alt && !k.win {
		switch {
		case sym == xkTab:
			k.down(sym, modAlt|shiftM, vkTab)
			return
		case lower == ' ':
			k.sync(0)
			k.tap(0, vkLWin) // Spotlight → Start search
			k.keys[sym] = pressed{nothing: true}
			return
		case lower == 'q' && !k.shift:
			k.tap(modAlt, vkF4)
			k.keys[sym] = pressed{nothing: true}
			return
		case lower == 'm' || lower == 'h':
			k.tap(modWin, vkDown) // minimize
			k.keys[sym] = pressed{nothing: true}
			return
		case k.shift && (r == '3' || r == '4' || r == '5' || r == '#' || r == '$' || r == '%'):
			k.tap(modWin|modShift, vkS) // screenshot → Snipping Tool
			k.keys[sym] = pressed{nothing: true}
			return
		case k.shift && lower == 'z':
			k.down(sym, modCtrl, vkY) // redo
			return
		case sym == xkLeft:
			k.down(sym, shiftM, vkHome)
			return
		case sym == xkRight:
			k.down(sym, shiftM, vkEnd)
			return
		case sym == xkUp:
			k.down(sym, modCtrl|shiftM, vkHome)
			return
		case sym == xkDown:
			k.down(sym, modCtrl|shiftM, vkEnd)
			return
		case sym == xkBackSpace: // delete to start of line
			k.tap(modShift, vkHome)
			k.tap(0, vkBack)
			k.keys[sym] = pressed{nothing: true}
			return
		}
	}
	if k.cmd && k.alt && !k.ctrl && sym == xkEscape { // Force Quit → Task Manager
		k.tap(modCtrl|modShift, vkEscape)
		k.keys[sym] = pressed{nothing: true}
		return
	}
	if k.cmd && k.ctrl && !k.alt && lower == 'q' { // Lock Screen
		k.tap(modWin, vkL)
		k.keys[sym] = pressed{nothing: true}
		return
	}
	if k.cmd && k.ctrl && !k.alt && lower == 'f' { // full screen
		k.down(sym, 0, vkF11)
		return
	}
	if k.alt && !k.cmd && !k.ctrl && !k.win {
		switch sym {
		case xkLeft, xkRight, xkBackSpace, xkDelete: // word-wise movement and deletion
			k.down(sym, modCtrl|shiftM, specialVK(sym))
			return
		}
	}
	if k.ctrl && !k.cmd && !k.alt && !k.shift && !k.win {
		switch sym {
		case xkUp, xkDown: // Mission Control / App Exposé → Task View
			k.tap(modWin, vkTab)
			k.keys[sym] = pressed{nothing: true}
			return
		case xkLeft, xkRight: // switch Spaces → switch virtual desktops
			k.down(sym, modWin|modCtrl, specialVK(sym))
			return
		}
	}

	want := k.plain()
	if vk := specialVK(sym); vk != 0 {
		k.down(sym, want, vk)
		return
	}
	if r == 0 {
		return
	}
	if want&(modCtrl|modAlt|modWin) == 0 {
		// Plain typing: inject the character itself so any keyboard layout types it right.
		k.sync(want)
		k.inj.Unicode(r, true)
		k.keys[sym] = pressed{r: r}
		return
	}
	// A shortcut: Windows needs the key, not the character.
	vk, needShift, ok := k.inj.CharKey(lower)
	if !ok {
		vk, needShift, ok = k.inj.CharKey(r)
	}
	if !ok {
		return
	}
	if needShift && lower == r && !unicode.IsLetter(r) {
		// e.g. ⌘+ arrives as '+', which needs Shift on most layouts (Ctrl+Shift+= zooms in).
		want |= modShift
	}
	k.down(sym, want, vk)
}

func (k *Keyboard) down(sym uint32, m mods, vk uint16) {
	k.sync(m)
	k.inj.Key(vk, true)
	k.keys[sym] = pressed{vk: vk}
}

// specialVK maps non-character keysyms to virtual keys (0 if it's a character).
func specialVK(sym uint32) uint16 {
	switch {
	case sym >= xkF1 && sym <= xkF12:
		return uint16(vkF1 + (sym - xkF1))
	}
	switch sym {
	case xkBackSpace:
		return vkBack
	case xkTab:
		return vkTab
	case xkReturn, xkKPEnter:
		return vkReturn
	case xkEscape:
		return vkEscape
	case xkDelete:
		return vkDelete
	case xkHome:
		return vkHome
	case xkEnd:
		return vkEnd
	case xkLeft:
		return vkLeft
	case xkRight:
		return vkRight
	case xkUp:
		return vkUp
	case xkDown:
		return vkDown
	case xkPageUp:
		return vkPrior
	case xkPageDown:
		return vkNext
	case xkInsert:
		return vkInsert
	case xkPrint:
		return vkSnapshot
	case xkMenu:
		return vkApps
	case xkCapsLock:
		return vkCapital
	case xkNumLock:
		return vkNumLock
	case ' ':
		return vkSpace
	}
	return 0
}

// keysymRune converts a keysym to the character it types (0 if none).
func keysymRune(sym uint32) rune {
	switch {
	case sym >= 0x20 && sym <= 0x7e, sym >= 0xa0 && sym <= 0xff:
		return rune(sym)
	case sym >= 0x01000100 && sym <= 0x0110ffff:
		return rune(sym - 0x01000000)
	}
	return 0
}

// Extended keys need KEYEVENTF_EXTENDEDKEY or Windows treats them as their numpad twins.
func isExtendedVK(vk uint16) bool {
	switch vk {
	case vkPrior, vkNext, vkEnd, vkHome, vkLeft, vkUp, vkRight, vkDown, vkInsert, vkDelete,
		vkLWin, 0x5C, vkApps, 0xA3, 0xA5, vkSnapshot, vkNumLock:
		return true
	}
	return false
}
