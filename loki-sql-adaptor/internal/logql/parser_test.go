package logql

import (
	"testing"
)

func TestParseStreamSelector(t *testing.T) {
	input := `{service_name="maas-gateway", subscription=~"simulator-subscription", model=~".+"}`
	q, err := Parse(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if q.Selector == nil {
		t.Fatal("expected Selector to be set")
	}
	if len(q.Selector.Matchers) != 3 {
		t.Fatalf("expected 3 matchers, got %d", len(q.Selector.Matchers))
	}

	m := q.Selector.Matchers[0]
	if m.Label != "service_name" || m.Op != MatchEqual || m.Value != "maas-gateway" {
		t.Errorf("matcher[0] = %+v", m)
	}
	m = q.Selector.Matchers[1]
	if m.Label != "subscription" || m.Op != MatchRegexp || m.Value != "simulator-subscription" {
		t.Errorf("matcher[1] = %+v", m)
	}
}

func TestParseSumOverTime(t *testing.T) {
	input := `sum(sum_over_time({service_name="maas-gateway", subscription=~".*"} | user_id=~".+" | user_id!="-" | unwrap tokens_total [$__range]))`
	q, err := Parse(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if q.VectorAgg == nil {
		t.Fatal("expected VectorAgg")
	}
	if q.VectorAgg.Op != "sum" {
		t.Errorf("expected sum, got %s", q.VectorAgg.Op)
	}
	inner := q.VectorAgg.Inner
	if inner.RangeAgg == nil {
		t.Fatal("expected inner RangeAgg")
	}
	if inner.RangeAgg.Op != "sum_over_time" {
		t.Errorf("expected sum_over_time, got %s", inner.RangeAgg.Op)
	}
	if inner.RangeAgg.Unwrap == nil || inner.RangeAgg.Unwrap.Field != "tokens_total" {
		t.Errorf("expected unwrap tokens_total, got %+v", inner.RangeAgg.Unwrap)
	}
	if inner.RangeAgg.Duration != "$__range" {
		t.Errorf("expected $__range duration, got %s", inner.RangeAgg.Duration)
	}
	if len(inner.RangeAgg.Filters) != 2 {
		t.Fatalf("expected 2 filters, got %d", len(inner.RangeAgg.Filters))
	}
}

func TestParseSumByModel(t *testing.T) {
	input := `sum by (model) (sum_over_time({service_name="maas-gateway", subscription=~".*", model=~".*"} | user_id=~".+" | user_id!="-" | unwrap tokens_total [30m]))`
	q, err := Parse(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if q.VectorAgg == nil {
		t.Fatal("expected VectorAgg")
	}
	if q.VectorAgg.Op != "sum" {
		t.Errorf("expected sum, got %s", q.VectorAgg.Op)
	}
	if len(q.VectorAgg.GroupBy) != 1 || q.VectorAgg.GroupBy[0] != "model" {
		t.Errorf("expected group by [model], got %v", q.VectorAgg.GroupBy)
	}
}

func TestParseCountOverTime(t *testing.T) {
	input := `sum(count_over_time({service_name="maas-gateway", subscription=~".*"} | user_id=~".+" | user_id!="-" [$__range]))`
	q, err := Parse(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if q.VectorAgg == nil || q.VectorAgg.Inner == nil || q.VectorAgg.Inner.RangeAgg == nil {
		t.Fatal("expected nested structure")
	}
	if q.VectorAgg.Inner.RangeAgg.Op != "count_over_time" {
		t.Errorf("expected count_over_time, got %s", q.VectorAgg.Inner.RangeAgg.Op)
	}
	if q.VectorAgg.Inner.RangeAgg.Unwrap != nil {
		t.Error("count_over_time should not have unwrap")
	}
}

func TestParseCountDistinctUsers(t *testing.T) {
	input := `count(sum by (user_id) (count_over_time({service_name="maas-gateway", subscription=~".*"} | user_id=~".+" | user_id!="" | user_id!="-" [$__range])))`
	q, err := Parse(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if q.VectorAgg == nil {
		t.Fatal("expected outer VectorAgg")
	}
	if q.VectorAgg.Op != "count" {
		t.Errorf("expected count, got %s", q.VectorAgg.Op)
	}
	inner := q.VectorAgg.Inner
	if inner.VectorAgg == nil {
		t.Fatal("expected inner VectorAgg (sum by user_id)")
	}
	if inner.VectorAgg.Op != "sum" {
		t.Errorf("expected inner sum, got %s", inner.VectorAgg.Op)
	}
	if len(inner.VectorAgg.GroupBy) != 1 || inner.VectorAgg.GroupBy[0] != "user_id" {
		t.Errorf("expected group by [user_id], got %v", inner.VectorAgg.GroupBy)
	}
}

func TestParseOrVectorSuffix(t *testing.T) {
	input := `sum(count_over_time({service_name="maas-gateway"} | user_id!="-" [$__range])) or vector(0)`
	q, err := Parse(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if q.VectorAgg == nil {
		t.Fatal("expected VectorAgg (or vector(0) should be ignored)")
	}
}

func TestParseBinOpDivision(t *testing.T) {
	input := `(sum(count_over_time({service_name="maas-gateway"} | response_code=~"2.." | user_id=~".+" | user_id!="-" [1h])) / sum(count_over_time({service_name="maas-gateway"} | user_id=~".+" | user_id!="-" [1h]))) or vector(1)`
	q, err := Parse(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if q.BinOp == nil {
		t.Fatal("expected BinOp")
	}
	if q.BinOp.Op != "/" {
		t.Errorf("expected /, got %s", q.BinOp.Op)
	}
	if q.BinOp.Left == nil || q.BinOp.Left.VectorAgg == nil {
		t.Fatal("expected left side to be a VectorAgg")
	}
	if q.BinOp.Right == nil || q.BinOp.Right.VectorAgg == nil {
		t.Fatal("expected right side to be a VectorAgg")
	}
}
