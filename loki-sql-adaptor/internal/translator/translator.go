package translator

import (
	"fmt"
	"strings"
	"time"

	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/logql"
)

type TranslatedQuery struct {
	SQL        string
	Args       []interface{}
	ResultType string // "scalar", "vector", "matrix"
	GroupBy    []string
	IsCount    bool // outer count() wrapping — means COUNT(DISTINCT ...)
}

type TimeRange struct {
	Start time.Time
	End   time.Time
	Step  time.Duration // for query_range time series bucketing
}

func Translate(q *logql.Query, tr TimeRange) (*TranslatedQuery, error) {
	if q.BinOp != nil {
		return translateBinOp(q.BinOp, tr)
	}
	if q.VectorAgg != nil {
		return translateVectorAgg(q.VectorAgg, tr)
	}
	if q.RangeAgg != nil {
		return translateRangeAgg(q.RangeAgg, nil, tr)
	}
	return nil, fmt.Errorf("unsupported query type (raw log queries not yet implemented)")
}

func translateBinOp(bo *logql.BinOp, tr TimeRange) (*TranslatedQuery, error) {
	left, err := Translate(bo.Left, tr)
	if err != nil {
		return nil, fmt.Errorf("left side of %s: %w", bo.Op, err)
	}
	right, err := Translate(bo.Right, tr)
	if err != nil {
		return nil, fmt.Errorf("right side of %s: %w", bo.Op, err)
	}

	sql := fmt.Sprintf("SELECT COALESCE((%s), 0) %s COALESCE((%s), 1) AS value",
		left.SQL, bo.Op, right.SQL)

	args := append(left.Args, right.Args...)

	return &TranslatedQuery{
		SQL:        sql,
		Args:       args,
		ResultType: "scalar",
	}, nil
}

func translateVectorAgg(va *logql.VectorAggregation, tr TimeRange) (*TranslatedQuery, error) {
	// Handle count(sum by (user_id) (...)) → COUNT(DISTINCT user_id)
	if va.Op == "count" && va.Inner != nil && va.Inner.VectorAgg != nil {
		innerVA := va.Inner.VectorAgg
		if innerVA.Op == "sum" && len(innerVA.GroupBy) > 0 && innerVA.Inner != nil && innerVA.Inner.RangeAgg != nil {
			return translateCountDistinct(innerVA.GroupBy, innerVA.Inner.RangeAgg, tr)
		}
	}

	if va.Inner == nil {
		return nil, fmt.Errorf("vector aggregation %s has no inner query", va.Op)
	}

	if va.Inner.RangeAgg != nil {
		return translateRangeAgg(va.Inner.RangeAgg, va, tr)
	}

	return nil, fmt.Errorf("unsupported inner query type for %s", va.Op)
}

func translateCountDistinct(groupBy []string, ra *logql.RangeAggregation, tr TimeRange) (*TranslatedQuery, error) {
	where, args := buildWhereClause(ra, tr)

	col := groupBy[0]
	sql := fmt.Sprintf(
		"SELECT COUNT(DISTINCT `%s`) AS value FROM usage_logs WHERE %s",
		col, where,
	)

	return &TranslatedQuery{
		SQL:        sql,
		Args:       args,
		ResultType: "scalar",
		IsCount:    true,
	}, nil
}

func translateRangeAgg(ra *logql.RangeAggregation, outerVA *logql.VectorAggregation, tr TimeRange) (*TranslatedQuery, error) {
	where, args := buildWhereClause(ra, tr)

	var groupBy []string
	if outerVA != nil {
		groupBy = outerVA.GroupBy
	}

	switch ra.Op {
	case "sum_over_time":
		return buildSumOverTime(ra, where, args, groupBy, tr)
	case "count_over_time":
		return buildCountOverTime(ra, where, args, groupBy, tr)
	default:
		return nil, fmt.Errorf("unsupported range aggregation: %s", ra.Op)
	}
}

func buildSumOverTime(ra *logql.RangeAggregation, where string, args []interface{}, groupBy []string, tr TimeRange) (*TranslatedQuery, error) {
	field := "tokens_total"
	if ra.Unwrap != nil {
		field = ra.Unwrap.Field
	}

	if len(groupBy) > 0 && tr.Step > 0 && shouldTimeBucket(ra.Duration, tr) {
		// Time series with grouping → matrix result
		bucketSec := int64(tr.Step.Seconds())
		groupCols := backtickJoin(groupBy)
		sql := fmt.Sprintf(
			"SELECT %s, UNIX_TIMESTAMP(FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(`timestamp`) / %d) * %d)) AS ts, "+
				"COALESCE(SUM(`%s`), 0) AS value FROM usage_logs WHERE %s GROUP BY %s, ts ORDER BY ts",
			groupCols, bucketSec, bucketSec, field, where, groupCols,
		)
		return &TranslatedQuery{SQL: sql, Args: args, ResultType: "matrix", GroupBy: groupBy}, nil
	}

	if len(groupBy) > 0 {
		// Grouped scalar (no time bucketing) — used when duration=$__range or covers full range
		groupCols := backtickJoin(groupBy)
		sql := fmt.Sprintf(
			"SELECT %s, COALESCE(SUM(`%s`), 0) AS value FROM usage_logs WHERE %s GROUP BY %s",
			groupCols, field, where, groupCols,
		)
		return &TranslatedQuery{SQL: sql, Args: args, ResultType: "vector", GroupBy: groupBy}, nil
	}

	// Scalar total
	sql := fmt.Sprintf(
		"SELECT COALESCE(SUM(`%s`), 0) AS value FROM usage_logs WHERE %s",
		field, where,
	)
	return &TranslatedQuery{SQL: sql, Args: args, ResultType: "scalar"}, nil
}

func buildCountOverTime(ra *logql.RangeAggregation, where string, args []interface{}, groupBy []string, tr TimeRange) (*TranslatedQuery, error) {
	if len(groupBy) > 0 && tr.Step > 0 && shouldTimeBucket(ra.Duration, tr) {
		bucketSec := int64(tr.Step.Seconds())
		groupCols := backtickJoin(groupBy)
		sql := fmt.Sprintf(
			"SELECT %s, UNIX_TIMESTAMP(FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(`timestamp`) / %d) * %d)) AS ts, "+
				"COUNT(*) AS value FROM usage_logs WHERE %s GROUP BY %s, ts ORDER BY ts",
			groupCols, bucketSec, bucketSec, where, groupCols,
		)
		return &TranslatedQuery{SQL: sql, Args: args, ResultType: "matrix", GroupBy: groupBy}, nil
	}

	if len(groupBy) > 0 {
		groupCols := backtickJoin(groupBy)
		sql := fmt.Sprintf(
			"SELECT %s, COUNT(*) AS value FROM usage_logs WHERE %s GROUP BY %s",
			groupCols, where, groupCols,
		)
		return &TranslatedQuery{SQL: sql, Args: args, ResultType: "vector", GroupBy: groupBy}, nil
	}

	sql := fmt.Sprintf("SELECT COUNT(*) AS value FROM usage_logs WHERE %s", where)
	return &TranslatedQuery{SQL: sql, Args: args, ResultType: "scalar"}, nil
}

func buildWhereClause(ra *logql.RangeAggregation, tr TimeRange) (string, []interface{}) {
	var conditions []string
	var args []interface{}

	// Time range
	conditions = append(conditions, "`timestamp` BETWEEN ? AND ?")
	args = append(args, tr.Start, tr.End)

	// Stream selector matchers (skip service_name — it's always "maas-gateway" in our table)
	for _, m := range ra.Selector.Matchers {
		if m.Label == "service_name" {
			continue
		}
		cond, arg := matcherToSQL(m.Label, m.Op, m.Value)
		if cond != "" {
			conditions = append(conditions, cond)
			if arg != nil {
				args = append(args, arg)
			}
		}
	}

	// Pipeline filters
	for _, f := range ra.Filters {
		cond, arg := matcherToSQL(f.Label, f.Op, f.Value)
		if cond != "" {
			conditions = append(conditions, cond)
			if arg != nil {
				args = append(args, arg)
			}
		}
	}

	return strings.Join(conditions, " AND "), args
}

func matcherToSQL(label string, op logql.MatchOp, value string) (string, interface{}) {
	col := fmt.Sprintf("`%s`", label)

	// response_code is numeric
	if label == "response_code" {
		switch op {
		case logql.MatchEqual:
			return fmt.Sprintf("CAST(%s AS CHAR) = ?", col), value
		case logql.MatchNotEqual:
			return fmt.Sprintf("CAST(%s AS CHAR) != ?", col), value
		case logql.MatchRegexp:
			return fmt.Sprintf("CAST(%s AS CHAR) REGEXP ?", col), convertRegex(value)
		case logql.MatchNotRegexp:
			return fmt.Sprintf("CAST(%s AS CHAR) NOT REGEXP ?", col), convertRegex(value)
		}
	}

	switch op {
	case logql.MatchEqual:
		return fmt.Sprintf("%s = ?", col), value
	case logql.MatchNotEqual:
		return fmt.Sprintf("%s != ?", col), value
	case logql.MatchRegexp:
		// .+ means "not empty" in our context
		if value == ".+" || value == ".*" {
			return "", nil // match-all, skip
		}
		return fmt.Sprintf("%s REGEXP ?", col), convertRegex(value)
	case logql.MatchNotRegexp:
		return fmt.Sprintf("%s NOT REGEXP ?", col), convertRegex(value)
	}
	return "", nil
}

// convertRegex handles basic Loki regex → MySQL REGEXP translation.
// Loki uses RE2; MySQL uses POSIX. Most simple patterns work as-is.
func convertRegex(pattern string) string {
	// Anchor: Loki regex is fully anchored by default, MySQL is not.
	// Wrap in ^(...)$ for equivalence.
	if !strings.HasPrefix(pattern, "^") {
		pattern = "^" + pattern
	}
	if !strings.HasSuffix(pattern, "$") {
		pattern = pattern + "$"
	}
	return pattern
}

// shouldTimeBucket returns true when the LogQL range duration indicates a
// concrete time window smaller than the query span. Full-range durations
// (like $__range or unparseable variables) should NOT be time-bucketed —
// instead they aggregate across the entire [start, end] interval.
func shouldTimeBucket(duration string, tr TimeRange) bool {
	if strings.HasPrefix(duration, "$") {
		return false
	}
	d := parseDuration(duration)
	if d == 0 {
		return false
	}
	totalRange := tr.End.Sub(tr.Start)
	return d < totalRange
}

func parseDuration(s string) time.Duration {
	if s == "" {
		return 0
	}
	var total time.Duration
	num := ""
	for _, ch := range s {
		if ch >= '0' && ch <= '9' {
			num += string(ch)
		} else {
			n := 0
			fmt.Sscanf(num, "%d", &n)
			num = ""
			switch ch {
			case 's':
				total += time.Duration(n) * time.Second
			case 'm':
				total += time.Duration(n) * time.Minute
			case 'h':
				total += time.Duration(n) * time.Hour
			case 'd':
				total += time.Duration(n) * 24 * time.Hour
			case 'w':
				total += time.Duration(n) * 7 * 24 * time.Hour
			}
		}
	}
	return total
}

func backtickJoin(labels []string) string {
	parts := make([]string, len(labels))
	for i, l := range labels {
		parts[i] = fmt.Sprintf("`%s`", l)
	}
	return strings.Join(parts, ", ")
}
