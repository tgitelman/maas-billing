package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"math/rand"
	"os"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// Synthetic data matching the dev cluster patterns from the Loki structured logs POC.
var (
	users = []string{
		"kube:admin",
		"test-loki-admin",
		"test-loki-viewer",
		"bob",
		"alice",
	}

	subscriptions = []string{
		"simulator-subscription",
		"standard-subscription",
		"sh-older-subscription",
	}

	models = []string{
		"facebook/opt-125m",
		"the-best-gpt-3.5-m",
		"meta-llama/Llama-3.2-1B-Instruct",
	}

	methods    = []string{"POST"}
	paths      = []string{"/v1/completions", "/v1/chat/completions"}
	routeNames = []string{"maas-route-completions", "maas-route-chat"}

	authorities = []string{
		"maas-default-gateway.openshift-ingress.svc:8080",
	}

	upstreamClusters = []string{
		"outbound|8080||facebook-opt-125m.models-as-a-service.svc.cluster.local",
		"outbound|8080||the-best-gpt-3-5-m.models-as-a-service.svc.cluster.local",
		"outbound|8080||meta-llama-3-2-1b.models-as-a-service.svc.cluster.local",
	}
)

func main() {
	dsn := os.Getenv("MYSQL_DSN")
	if dsn == "" {
		log.Fatal("MYSQL_DSN environment variable is required")
	}

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer db.Close()

	ctx := context.Background()
	numRecords := 500
	log.Printf("Generating %d synthetic usage records...", numRecords)

	now := time.Now()
	baseTime := now.Add(-7 * 24 * time.Hour) // 7 days of data

	stmt, err := db.PrepareContext(ctx, `
		INSERT INTO usage_logs (
			timestamp, user_id, subscription, model,
			tokens_total, tokens_prompt, tokens_completion,
			response_code, method, path, duration_ms,
			request_id, authority, route_name,
			downstream_remote_address, upstream_cluster,
			bytes_received, bytes_sent, response_code_details
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`)
	if err != nil {
		log.Fatalf("Prepare statement: %v", err)
	}
	defer stmt.Close()

	inserted := 0
	for i := 0; i < numRecords; i++ {
		ts := baseTime.Add(time.Duration(rand.Int63n(int64(7 * 24 * time.Hour))))
		user := users[rand.Intn(len(users))]
		sub := subscriptions[rand.Intn(len(subscriptions))]
		modelIdx := rand.Intn(len(models))
		model := models[modelIdx]
		method := methods[rand.Intn(len(methods))]
		path := paths[rand.Intn(len(paths))]
		route := routeNames[rand.Intn(len(routeNames))]
		authority := authorities[0]
		upstream := upstreamClusters[modelIdx%len(upstreamClusters)]

		// 85% success, 15% rate-limited
		responseCode := 200
		responseDetails := "via_upstream"
		tokensPrompt := rand.Intn(50) + 5
		tokensCompletion := rand.Intn(30) + 3
		tokensTotal := tokensPrompt + tokensCompletion

		if rand.Float64() < 0.15 {
			responseCode = 429
			responseDetails = "rate_limited"
			tokensTotal = 0
			tokensPrompt = 0
			tokensCompletion = 0
		}

		durationMs := rand.Intn(2000) + 50
		requestID := fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
			rand.Int31(), rand.Int31n(0xffff), rand.Int31n(0xffff),
			rand.Int31n(0xffff), rand.Int63n(0xffffffffffff))
		downstreamAddr := fmt.Sprintf("10.%d.%d.%d:%d",
			rand.Intn(255), rand.Intn(255), rand.Intn(255), 30000+rand.Intn(30000))
		bytesReceived := rand.Intn(2000) + 100
		bytesSent := rand.Intn(5000) + 200

		_, err := stmt.ExecContext(ctx,
			ts, user, sub, model,
			tokensTotal, tokensPrompt, tokensCompletion,
			responseCode, method, path, durationMs,
			requestID, authority, route,
			downstreamAddr, upstream,
			bytesReceived, bytesSent, responseDetails,
		)
		if err != nil {
			log.Printf("Insert error (row %d): %v", i, err)
			continue
		}
		inserted++
	}

	log.Printf("Done: inserted %d/%d records over 7-day window", inserted, numRecords)

	// Print summary
	var count int
	db.QueryRowContext(ctx, "SELECT COUNT(*) FROM usage_logs").Scan(&count)
	log.Printf("Total records in usage_logs: %d", count)

	var distinctUsers int
	db.QueryRowContext(ctx, "SELECT COUNT(DISTINCT user_id) FROM usage_logs WHERE user_id != '-'").Scan(&distinctUsers)
	log.Printf("Distinct users: %d", distinctUsers)

	var totalTokens int64
	db.QueryRowContext(ctx, "SELECT COALESCE(SUM(tokens_total), 0) FROM usage_logs").Scan(&totalTokens)
	log.Printf("Total tokens: %d", totalTokens)
}
