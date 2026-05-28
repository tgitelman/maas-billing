package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	_ "github.com/go-sql-driver/mysql"

	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/db/schema"
)

type Store struct {
	db *sql.DB
}

func New(dsn string) (*Store, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("open mysql: %w", err)
	}

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(5 * time.Minute)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		return nil, fmt.Errorf("ping mysql: %w", err)
	}

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}

	return s, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) DB() *sql.DB {
	return s.db
}

func (s *Store) migrate() error {
	entries, err := schema.Migrations.ReadDir(".")
	if err != nil {
		return fmt.Errorf("read migrations dir: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		content, err := schema.Migrations.ReadFile(entry.Name())
		if err != nil {
			return fmt.Errorf("read migration %s: %w", entry.Name(), err)
		}
		if _, err := s.db.Exec(string(content)); err != nil {
			return fmt.Errorf("exec migration %s: %w", entry.Name(), err)
		}
	}

	return nil
}

type QueryResult struct {
	ResultType string
	Matrix     []MatrixSeries
	Vector     []VectorSample
}

type MatrixSeries struct {
	Labels map[string]string
	Values []SamplePair
}

type SamplePair struct {
	Timestamp int64
	Value     string
}

type VectorSample struct {
	Labels map[string]string
	Value  SamplePair
}

func (s *Store) ExecuteQuery(ctx context.Context, query string, args []interface{}) (*sql.Rows, error) {
	return s.db.QueryContext(ctx, query, args...)
}

func (s *Store) Labels(ctx context.Context) ([]string, error) {
	return []string{
		"user_id",
		"subscription",
		"model",
		"response_code",
		"method",
		"path",
		"authority",
		"route_name",
		"upstream_cluster",
	}, nil
}

func (s *Store) LabelValues(ctx context.Context, label string) ([]string, error) {
	allowedLabels := map[string]bool{
		"user_id": true, "subscription": true, "model": true,
		"response_code": true, "method": true, "path": true,
		"authority": true, "route_name": true, "upstream_cluster": true,
	}
	if !allowedLabels[label] {
		return []string{}, nil
	}

	query := fmt.Sprintf("SELECT DISTINCT `%s` FROM usage_logs WHERE `%s` != '' ORDER BY `%s`", label, label, label)
	rows, err := s.db.QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("label values query: %w", err)
	}
	defer rows.Close()

	var values []string
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		values = append(values, v)
	}
	return values, rows.Err()
}
