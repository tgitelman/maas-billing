package translator

import (
	"strings"
	"testing"
	"time"

	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/logql"
)

func TestTranslateTotalTokens(t *testing.T) {
	input := `sum(sum_over_time({service_name="maas-gateway", subscription=~"simulator-subscription", model=~".*"} | user_id=~".+" | user_id!="-" | unwrap tokens_total [$__range]))`
	q, err := logql.Parse(input)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	tr := TimeRange{
		Start: time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		End:   time.Date(2026, 5, 2, 0, 0, 0, 0, time.UTC),
	}

	result, err := Translate(q, tr)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}

	if result.ResultType != "scalar" {
		t.Errorf("expected scalar, got %s", result.ResultType)
	}
	if !strings.Contains(result.SQL, "SUM(`tokens_total`)") {
		t.Errorf("expected SUM(tokens_total) in SQL: %s", result.SQL)
	}
	if !strings.Contains(result.SQL, "`subscription` REGEXP ?") {
		t.Errorf("expected subscription REGEXP in SQL: %s", result.SQL)
	}
	if !strings.Contains(result.SQL, "`user_id` != ?") {
		t.Errorf("expected user_id != in SQL: %s", result.SQL)
	}
}

func TestTranslateSumByModel(t *testing.T) {
	input := `sum by (model) (sum_over_time({service_name="maas-gateway", subscription=~".*", model=~".*"} | user_id=~".+" | user_id!="-" | unwrap tokens_total [30m]))`
	q, err := logql.Parse(input)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	tr := TimeRange{
		Start: time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		End:   time.Date(2026, 5, 2, 0, 0, 0, 0, time.UTC),
		Step:  30 * time.Minute,
	}

	result, err := Translate(q, tr)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}

	if result.ResultType != "matrix" {
		t.Errorf("expected matrix, got %s", result.ResultType)
	}
	if !strings.Contains(result.SQL, "GROUP BY `model`, ts") {
		t.Errorf("expected GROUP BY model, ts in SQL: %s", result.SQL)
	}
}

func TestTranslateCountDistinctUsers(t *testing.T) {
	input := `count(sum by (user_id) (count_over_time({service_name="maas-gateway", subscription=~".*"} | user_id=~".+" | user_id!="" | user_id!="-" [$__range])))`
	q, err := logql.Parse(input)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	tr := TimeRange{
		Start: time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		End:   time.Date(2026, 5, 2, 0, 0, 0, 0, time.UTC),
	}

	result, err := Translate(q, tr)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}

	if result.ResultType != "scalar" {
		t.Errorf("expected scalar, got %s", result.ResultType)
	}
	if !strings.Contains(result.SQL, "COUNT(DISTINCT `user_id`)") {
		t.Errorf("expected COUNT(DISTINCT user_id) in SQL: %s", result.SQL)
	}
}

func TestTranslateCountOverTime(t *testing.T) {
	input := `sum(count_over_time({service_name="maas-gateway", subscription=~".*"} | user_id=~".+" | user_id!="-" [$__range]))`
	q, err := logql.Parse(input)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	tr := TimeRange{
		Start: time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		End:   time.Date(2026, 5, 2, 0, 0, 0, 0, time.UTC),
	}

	result, err := Translate(q, tr)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}

	if result.ResultType != "scalar" {
		t.Errorf("expected scalar, got %s", result.ResultType)
	}
	if !strings.Contains(result.SQL, "COUNT(*)") {
		t.Errorf("expected COUNT(*) in SQL: %s", result.SQL)
	}
}
