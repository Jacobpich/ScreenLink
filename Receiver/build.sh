#!/bin/zsh
# Builds ScreenLinkReceiver.exe (Windows x64 and ARM64) from this Mac.
# Uses the Go toolchain in .toolchain/ (download from go.dev/dl if missing).
set -e
cd "$(dirname "$0")"
export PATH=$PWD/.toolchain/go/bin:$PATH GOCACHE=$PWD/.toolchain/cache GOPATH=$PWD/.toolchain/gopath
go vet ./... && GOOS=windows GOARCH=amd64 go vet ./...
go test ./...
mkdir -p dist
GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-H windowsgui -s -w" -o dist/ScreenLinkReceiver.exe .
GOOS=windows GOARCH=arm64 go build -trimpath -ldflags "-H windowsgui -s -w" -o dist/ScreenLinkReceiver-arm64.exe .
go build -o .toolchain/receiver-test .   # Mac test build with a fake desktop
ls -la dist
