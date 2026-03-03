.PHONY: build clean test
.DEFAULT_GOAL := build

build:
	go build -o ./build/BIGBROTHER ./internal/cmd/hub

test:
	go test ./...

clean:
	rm -rf ./build
