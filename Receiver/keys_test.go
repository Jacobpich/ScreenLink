package main

import (
	"fmt"
	"strings"
	"testing"
	"unicode"
)

type rec struct{ log []string }

func (r *rec) Key(vk uint16, down bool) {
	r.log = append(r.log, fmt.Sprintf("%s%s", name(vk), arrow(down)))
}
func (r *rec) Unicode(c rune, down bool) {
	r.log = append(r.log, fmt.Sprintf("'%c'%s", c, arrow(down)))
}
func (r *rec) CharKey(c rune) (uint16, bool, bool) {
	switch {
	case c >= 'a' && c <= 'z':
		return uint16(unicode.ToUpper(c)), false, true
	case c >= '0' && c <= '9':
		return uint16(c), false, true
	case c == '=':
		return 0xBB, false, true
	case c == '+':
		return 0xBB, true, true
	}
	return 0, false, false
}
func arrow(d bool) string {
	if d {
		return "↓"
	}
	return "↑"
}
func name(vk uint16) string {
	n := map[uint16]string{vkLControl: "Ctrl", vkLMenu: "Alt", vkLShift: "Shift", vkLWin: "Win", vkTab: "Tab",
		vkF4: "F4", vkHome: "Home", vkEnd: "End", vkLeft: "Left", vkRight: "Right", vkBack: "Back", vkUp: "Up",
		vkEscape: "Esc", vkDown: "Down", 0xBB: "=", vkSpace: "Space", vkReturn: "Enter"}
	if s, ok := n[vk]; ok {
		return s
	}
	if vk >= 'A' && vk <= 'Z' || vk >= '0' && vk <= '9' {
		return string(rune(vk))
	}
	return fmt.Sprintf("vk%02X", vk)
}

// run plays a sequence like "+cmd +c -c -cmd" and returns what Windows received.
func run(seq string) string {
	r := &rec{}
	k := NewKeyboard(r)
	syms := map[string]uint32{"cmd": xkMetaL, "ctrl": xkControlL, "alt": xkAltL, "shift": xkShiftL, "win": xkSuperL,
		"tab": xkTab, "left": xkLeft, "right": xkRight, "up": xkUp, "down": xkDown, "bs": xkBackSpace,
		"esc": xkEscape, "space": ' ', "enter": xkReturn}
	for _, ev := range strings.Fields(seq) {
		down := ev[0] == '+'
		n := ev[1:]
		sym, ok := syms[n]
		if !ok {
			sym = uint32([]rune(n)[0])
		}
		k.Event(sym, down)
	}
	return strings.Join(r.log, " ")
}

func TestKeyboard(t *testing.T) {
	cases := []struct{ in, want string }{
		{"+h -h +i -i", "'h'↓ 'h'↑ 'i'↓ 'i'↑"},
		{"+shift +A -A -shift", "Shift↓ 'A'↓ 'A'↑ Shift↑"},
		{"+cmd -cmd", ""},
		{"+cmd +c -c -cmd", "Ctrl↓ C↓ C↑ Ctrl↑"},
		{"+cmd +c -c +v -v -cmd", "Ctrl↓ C↓ C↑ V↓ V↑ Ctrl↑"},
		{"+cmd +tab -tab +tab -tab -cmd", "Alt↓ Tab↓ Tab↑ Tab↓ Tab↑ Alt↑"},
		{"+cmd +space -space -cmd", "Win↓ Win↑"},
		{"+cmd +q -q -cmd", "Alt↓ F4↓ F4↑ Alt↑"},
		{"+alt +left -left -alt", "Ctrl↓ Left↓ Left↑ Ctrl↑"},
		{"+shift +alt +right -right -alt -shift", "Ctrl↓ Shift↓ Right↓ Right↑ Ctrl↑ Shift↑"},
		{"+cmd +left -left -cmd", "Home↓ Home↑"},
		{"+cmd +shift +left -left -shift -cmd", "Shift↓ Home↓ Home↑ Shift↑"},
		{"+ctrl +up -up -ctrl", "Win↓ Tab↓ Tab↑ Win↑"},
		{"+ctrl +cmd +q -q -cmd -ctrl", "Win↓ L↓ L↑ Win↑"},
		{"+cmd +alt +esc -esc -alt -cmd", "Ctrl↓ Shift↓ Esc↓ Esc↑ Shift↑ Ctrl↑"},
		{"+cmd +shift +4 -4 -shift -cmd", "Shift↓ Win↓ S↓ S↑ Shift↑ Win↑"},
		{"+cmd +shift +z -z -shift -cmd", "Ctrl↓ Y↓ Y↑ Ctrl↑"},
		{"+cmd ++ -+ -cmd", "Ctrl↓ Shift↓ =↓ =↑ Ctrl↑ Shift↑"},
		{"+win -win", "Win↓ Win↑"},
		{"+win +d -d -win", "Win↓ D↓ D↑ Win↑"},
		{"+cmd +bs -bs -cmd", "Shift↓ Home↓ Home↑ Shift↑ Back↓ Back↑"},
		{"+enter -enter +space -space", "Enter↓ Enter↑ Space↓ Space↑"},
		{"+ctrl +c -c -ctrl", "Ctrl↓ C↓ C↑ Ctrl↑"},
	}
	for _, c := range cases {
		if got := run(c.in); got != c.want {
			t.Errorf("%s\n  got  %s\n  want %s", c.in, got, c.want)
		}
	}
}
