package config

import (
	"fmt"
	"os"
)

type Config struct {
	MySQLDSN   string
	ListenAddr string
}

func Load() (*Config, error) {
	dsn := os.Getenv("MYSQL_DSN")
	if dsn == "" {
		return nil, fmt.Errorf("MYSQL_DSN environment variable is required")
	}

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}

	return &Config{
		MySQLDSN:   dsn,
		ListenAddr: addr,
	}, nil
}
