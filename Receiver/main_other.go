//go:build !windows

package main

import (
	"flag"
	"log"
	"os"
)

// On a Mac this runs the receiver against a fake desktop, for testing ScreenLink.
func main() {
	port := flag.Int("port", 5990, "port")
	pass := flag.String("password", "test-pass-1", "password")
	dump := flag.String("dump", "", "write one captured frame (BGRA) to this file and exit")
	flag.Parse()
	if *dump != "" {
		img, _, _, _ := newPlatform().Capture()
		if err := os.WriteFile(*dump, img, 0o644); err != nil {
			log.Fatal(err)
		}
		return
	}
	cfg := &Config{Port: *port, ScrollStep: 40}
	cfg.setPassword(*pass)
	l, err := listen(cfg)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("%s (test desktop) listening on %d", appName, *port)
	log.Fatal(NewServer(cfg, newPlatform()).Serve(l))
}
