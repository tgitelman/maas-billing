FROM golang:1.25 AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /loki-sql-adaptor ./cmd/server

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /loki-sql-adaptor /loki-sql-adaptor
USER 65532:65532
ENTRYPOINT ["/loki-sql-adaptor"]
