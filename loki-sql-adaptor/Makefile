MODULE := github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor
BINARY := loki-sql-adaptor
SEED_BINARY := seeddata
IMG ?= loki-sql-adaptor:latest

.PHONY: build build-seed test lint run run-seed clean docker-build

build:
	go build -o bin/$(BINARY) ./cmd/server

build-seed:
	go build -o bin/$(SEED_BINARY) ./cmd/seeddata

test:
	go test -race ./...

lint:
	golangci-lint run ./...

run: build
	./bin/$(BINARY)

run-seed: build-seed
	./bin/$(SEED_BINARY)

clean:
	rm -rf bin/

docker-build:
	docker build -t $(IMG) .

tidy:
	go mod tidy
