package logql

// StreamSelector represents {label="value", label=~"regex"} matchers.
type StreamSelector struct {
	Matchers []Matcher
}

type MatchOp int

const (
	MatchEqual    MatchOp = iota // =
	MatchNotEqual                // !=
	MatchRegexp                  // =~
	MatchNotRegexp               // !~
)

type Matcher struct {
	Label string
	Op    MatchOp
	Value string
}

// PipelineFilter represents | label op "value" filters after the stream selector.
type PipelineFilter struct {
	Label string
	Op    MatchOp
	Value string
}

// UnwrapExpr represents | unwrap <field>.
type UnwrapExpr struct {
	Field string
}

// RangeAggregation represents sum_over_time(...[duration]) or count_over_time(...[duration]).
type RangeAggregation struct {
	Op       string // "sum_over_time" or "count_over_time"
	Selector StreamSelector
	Filters  []PipelineFilter
	Unwrap   *UnwrapExpr
	Duration string // e.g. "5m", "1h", "$__range"
}

// VectorAggregation represents sum(...), sum by (label) (...), count(...).
type VectorAggregation struct {
	Op      string   // "sum", "count"
	GroupBy []string // labels for "by (label1, label2)"
	Inner   *Query
}

// BinOp represents a binary operation (e.g., division for success rate).
type BinOp struct {
	Op    string // "/", "*", "+", "-"
	Left  *Query
	Right *Query
}

// Query is the top-level AST node.
type Query struct {
	// Exactly one of these is set:
	RangeAgg  *RangeAggregation
	VectorAgg *VectorAggregation
	BinOp     *BinOp
	// For raw log queries (no metric wrapper):
	Selector *StreamSelector
	Filters  []PipelineFilter
}
