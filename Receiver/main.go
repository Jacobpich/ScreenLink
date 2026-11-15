package main

import (
	"fmt"
	"net"
	"strconv"
)

const appName = "ScreenLink Receiver"

// listen opens the ScreenLink port on all interfaces (connections from outside Tailscale are
// refused by Config.allowed).
func listen(cfg *Config) (net.Listener, error) {
	l, err := net.Listen("tcp", ":"+strconv.Itoa(cfg.Port))
	if err != nil {
		return nil, fmt.Errorf("port %d is busy (another screen sharing app may be using it): %w", cfg.Port, err)
	}
	return l, nil
}
