package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/config"
	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/handlers"
	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/store"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	s, err := store.New(cfg.MySQLDSN)
	if err != nil {
		log.Fatalf("Failed to connect to MySQL: %v", err)
	}
	defer s.Close()

	log.Printf("Connected to MySQL, migrations applied")

	router := gin.Default()
	h := handlers.New(s)

	// Loki-compatible API endpoints
	router.GET("/loki/api/v1/query_range", h.QueryRange)
	router.GET("/loki/api/v1/query", h.Query)
	router.GET("/loki/api/v1/labels", h.Labels)
	router.GET("/loki/api/v1/label/:name/values", h.LabelValues)

	// Health check
	router.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{"status": "ok"})
	})

	srv := &http.Server{
		Addr:         cfg.ListenAddr,
		Handler:      router,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 60 * time.Second,
	}

	go func() {
		log.Printf("Starting loki-sql-adaptor on %s", cfg.ListenAddr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Shutdown error: %v", err)
	}
	log.Println("Server stopped")
}
