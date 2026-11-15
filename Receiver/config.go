package main

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync"
)

type Config struct {
	Port int `json:"port"`
	// Salted PBKDF2 hash of the password; the password itself is never stored.
	Salt string `json:"salt"`
	Hash string `json:"hash"`
	// Allow viewers on the local network too (default: Tailscale devices only).
	AllowLAN bool `json:"allowLAN"`
	// Wheel units per ScreenLink scroll notch (120 = one classic mouse-wheel click).
	ScrollStep int `json:"scrollStep"`

	path string
	mu   sync.Mutex
}

// reload picks up a password changed by the setup window while the receiver is running.
func (c *Config) reload() {
	if c.path == "" {
		return
	}
	fresh := loadConfig()
	c.mu.Lock()
	c.Salt, c.Hash = fresh.Salt, fresh.Hash
	c.mu.Unlock()
}

func configDir() string {
	d, err := os.UserConfigDir()
	if err != nil {
		d = "."
	}
	return filepath.Join(d, "ScreenLink Receiver")
}

func loadConfig() *Config {
	c := &Config{Port: 5900, ScrollStep: 40, path: filepath.Join(configDir(), "config.json")}
	if b, err := os.ReadFile(c.path); err == nil {
		json.Unmarshal(b, c)
	}
	if c.Port == 0 {
		c.Port = 5900
	}
	if c.ScrollStep == 0 {
		c.ScrollStep = 40
	}
	return c
}

func (c *Config) save() error {
	if err := os.MkdirAll(filepath.Dir(c.path), 0o700); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(c, "", "  ")
	return os.WriteFile(c.path, b, 0o600)
}

func (c *Config) configured() bool { return c.Hash != "" }

func hashPassword(pass string, salt []byte) []byte {
	k, _ := pbkdf2.Key(sha256.New, pass, salt, 200_000, 32)
	return k
}

func (c *Config) setPassword(pass string) {
	salt := make([]byte, 16)
	rand.Read(salt)
	c.Salt = hex.EncodeToString(salt)
	c.Hash = hex.EncodeToString(hashPassword(pass, salt))
}

func (c *Config) checkPassword(pass string) bool {
	c.mu.Lock()
	saltHex, hashHex := c.Salt, c.Hash
	c.mu.Unlock()
	salt, err1 := hex.DecodeString(saltHex)
	want, err2 := hex.DecodeString(hashHex)
	if err1 != nil || err2 != nil || len(want) == 0 {
		return false
	}
	return subtle.ConstantTimeCompare(hashPassword(pass, salt), want) == 1
}

var tailnets = []*net.IPNet{mustCIDR("100.64.0.0/10"), mustCIDR("fd7a:115c:a1e0::/48")}
var lans = []*net.IPNet{mustCIDR("10.0.0.0/8"), mustCIDR("172.16.0.0/12"), mustCIDR("192.168.0.0/16"), mustCIDR("fe80::/10")}

func mustCIDR(s string) *net.IPNet {
	_, n, err := net.ParseCIDR(s)
	if err != nil {
		panic(err)
	}
	return n
}

// allowed: Tailscale addresses (and this PC itself); LAN addresses only if turned on.
func (c *Config) allowed(ip net.IP) bool {
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	for _, n := range tailnets {
		if n.Contains(ip) {
			return true
		}
	}
	if c.AllowLAN {
		for _, n := range lans {
			if n.Contains(ip) {
				return true
			}
		}
	}
	return false
}

// tailscaleIP returns this machine's Tailscale IPv4 address, if Tailscale is running.
func tailscaleIP() string {
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && tailnets[0].Contains(n.IP) {
			return n.IP.String()
		}
	}
	return ""
}
