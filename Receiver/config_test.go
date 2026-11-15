package main

import (
	"net"
	"testing"
)

func TestAllowedLAN(t *testing.T) {
	c := &Config{}
	cases := []struct {
		ip      string
		off, on bool
	}{
		{"100.101.102.103", true, true},
		{"127.0.0.1", true, true},
		{"192.168.1.20", false, true},
		{"10.0.0.5", false, true},
		{"8.8.8.8", false, false},
	}
	for _, tc := range cases {
		c.AllowLAN = false
		if got := c.allowed(net.ParseIP(tc.ip)); got != tc.off {
			t.Errorf("%s with Wi-Fi off: got %v", tc.ip, got)
		}
		c.AllowLAN = true
		if got := c.allowed(net.ParseIP(tc.ip)); got != tc.on {
			t.Errorf("%s with Wi-Fi on: got %v", tc.ip, got)
		}
	}
	if c.firewallRemote() != "100.64.0.0/10,LocalSubnet" {
		t.Error(c.firewallRemote())
	}
}
