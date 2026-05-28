package handlers

import (
	"fmt"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/logql"
	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/store"
	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/translator"
)

type Handler struct {
	store *store.Store
}

func New(s *store.Store) *Handler {
	return &Handler{store: s}
}

// QueryRange handles GET /loki/api/v1/query_range
func (h *Handler) QueryRange(c *gin.Context) {
	query := c.Query("query")
	if query == "" {
		errorResponse(c, 400, "query parameter is required")
		return
	}

	start, end, step, err := parseTimeRange(c)
	if err != nil {
		errorResponse(c, 400, err.Error())
		return
	}

	parsed, err := logql.Parse(query)
	if err != nil {
		errorResponse(c, 400, fmt.Sprintf("failed to parse LogQL: %v", err))
		return
	}

	tr := translator.TimeRange{Start: start, End: end, Step: step}
	translated, err := translator.Translate(parsed, tr)
	if err != nil {
		errorResponse(c, 400, fmt.Sprintf("failed to translate query: %v", err))
		return
	}

	rows, err := h.store.ExecuteQuery(c.Request.Context(), translated.SQL, translated.Args)
	if err != nil {
		errorResponse(c, 500, fmt.Sprintf("query execution failed: %v", err))
		return
	}
	defer rows.Close()

	switch translated.ResultType {
	case "scalar":
		h.handleScalarAsMatrix(c, rows, start, end, step)
	case "vector":
		h.handleVectorAsMatrix(c, rows, translated.GroupBy, start, end, step)
	case "matrix":
		h.handleMatrixResult(c, rows, translated.GroupBy)
	default:
		errorResponse(c, 500, "unknown result type")
	}
}

// handleScalarAsMatrix wraps a single scalar value as a matrix series for query_range.
// Loki's query_range always returns matrix, even for scalar aggregations.
func (h *Handler) handleScalarAsMatrix(c *gin.Context, rows interface{ Next() bool; Scan(...interface{}) error; Err() error }, start, end time.Time, step time.Duration) {
	var value float64
	if rows.Next() {
		if err := rows.Scan(&value); err != nil {
			errorResponse(c, 500, fmt.Sprintf("scan error: %v", err))
			return
		}
	}

	values := buildConstantSeries(value, start, end, step)
	successResponse(c, "matrix", []MatrixResult{{
		Metric: map[string]string{},
		Values: values,
	}})
}

// handleVectorAsMatrix wraps grouped vector results as matrix series for query_range.
func (h *Handler) handleVectorAsMatrix(c *gin.Context, rows interface{ Next() bool; Scan(...interface{}) error; Err() error }, groupBy []string, start, end time.Time, step time.Duration) {
	var results []MatrixResult

	for rows.Next() {
		labels := make([]string, len(groupBy))
		scanDest := make([]interface{}, len(groupBy)+1)
		for i := range labels {
			scanDest[i] = &labels[i]
		}
		var value float64
		scanDest[len(groupBy)] = &value

		if err := rows.Scan(scanDest...); err != nil {
			errorResponse(c, 500, fmt.Sprintf("scan error: %v", err))
			return
		}

		metric := make(map[string]string)
		for i, l := range groupBy {
			metric[l] = labels[i]
		}

		values := buildConstantSeries(value, start, end, step)
		results = append(results, MatrixResult{
			Metric: metric,
			Values: values,
		})
	}

	if err := rows.(interface{ Err() error }).Err(); err != nil {
		errorResponse(c, 500, fmt.Sprintf("rows error: %v", err))
		return
	}

	if results == nil {
		results = []MatrixResult{}
	}
	successResponse(c, "matrix", results)
}

// handleScalarResult handles scalar results for instant queries.
func (h *Handler) handleScalarResult(c *gin.Context, rows interface{ Next() bool; Scan(...interface{}) error; Err() error }, endTime time.Time) {
	if !rows.Next() {
		successResponse(c, "vector", []VectorResult{{
			Metric: map[string]string{},
			Value:  []interface{}{endTime.Unix(), "0"},
		}})
		return
	}

	var value float64
	if err := rows.Scan(&value); err != nil {
		errorResponse(c, 500, fmt.Sprintf("scan error: %v", err))
		return
	}

	successResponse(c, "vector", []VectorResult{{
		Metric: map[string]string{},
		Value:  []interface{}{endTime.Unix(), formatValue(value)},
	}})
}

// buildConstantSeries creates a time series with a constant value at each step.
// For stat panels (calculation: last), even a single point suffices.
func buildConstantSeries(value float64, start, end time.Time, step time.Duration) [][]interface{} {
	if step <= 0 {
		step = end.Sub(start)
		if step <= 0 {
			step = time.Minute
		}
	}

	totalSteps := int(end.Sub(start) / step)
	if totalSteps > 200 {
		step = end.Sub(start) / 200
	}

	formatted := formatValue(value)
	var values [][]interface{}
	for t := start; !t.After(end); t = t.Add(step) {
		values = append(values, []interface{}{t.Unix(), formatted})
	}
	if len(values) == 0 {
		values = append(values, []interface{}{end.Unix(), formatted})
	}
	return values
}

func (h *Handler) handleVectorResult(c *gin.Context, rows interface{ Next() bool; Scan(...interface{}) error; Err() error }, groupBy []string, endTime time.Time) {
	var results []VectorResult

	for rows.Next() {
		labels := make([]string, len(groupBy))
		scanDest := make([]interface{}, len(groupBy)+1)
		for i := range labels {
			scanDest[i] = &labels[i]
		}
		var value float64
		scanDest[len(groupBy)] = &value

		if err := rows.Scan(scanDest...); err != nil {
			errorResponse(c, 500, fmt.Sprintf("scan error: %v", err))
			return
		}

		metric := make(map[string]string)
		for i, l := range groupBy {
			metric[l] = labels[i]
		}

		results = append(results, VectorResult{
			Metric: metric,
			Value:  []interface{}{endTime.Unix(), formatValue(value)},
		})
	}

	if err := rows.(interface{ Err() error }).Err(); err != nil {
		errorResponse(c, 500, fmt.Sprintf("rows error: %v", err))
		return
	}

	if results == nil {
		results = []VectorResult{}
	}
	successResponse(c, "vector", results)
}

func (h *Handler) handleMatrixResult(c *gin.Context, rows interface{ Next() bool; Scan(...interface{}) error; Err() error }, groupBy []string) {
	seriesMap := make(map[string]*MatrixResult)

	for rows.Next() {
		labels := make([]string, len(groupBy))
		scanDest := make([]interface{}, len(groupBy)+2)
		for i := range labels {
			scanDest[i] = &labels[i]
		}
		var ts int64
		var value float64
		scanDest[len(groupBy)] = &ts
		scanDest[len(groupBy)+1] = &value

		if err := rows.Scan(scanDest...); err != nil {
			errorResponse(c, 500, fmt.Sprintf("scan error: %v", err))
			return
		}

		key := ""
		metric := make(map[string]string)
		for i, l := range groupBy {
			metric[l] = labels[i]
			key += labels[i] + "|"
		}

		series, ok := seriesMap[key]
		if !ok {
			series = &MatrixResult{Metric: metric}
			seriesMap[key] = series
		}
		series.Values = append(series.Values, []interface{}{ts, formatValue(value)})
	}

	if err := rows.(interface{ Err() error }).Err(); err != nil {
		errorResponse(c, 500, fmt.Sprintf("rows error: %v", err))
		return
	}

	results := make([]MatrixResult, 0, len(seriesMap))
	for _, s := range seriesMap {
		results = append(results, *s)
	}
	successResponse(c, "matrix", results)
}

func parseTimeRange(c *gin.Context) (time.Time, time.Time, time.Duration, error) {
	startStr := c.Query("start")
	endStr := c.Query("end")
	stepStr := c.Query("step")

	start, err := parseTime(startStr)
	if err != nil {
		return time.Time{}, time.Time{}, 0, fmt.Errorf("invalid start: %w", err)
	}
	end, err := parseTime(endStr)
	if err != nil {
		return time.Time{}, time.Time{}, 0, fmt.Errorf("invalid end: %w", err)
	}

	var step time.Duration
	if stepStr != "" {
		// Try as seconds first (Loki sends step as number of seconds)
		if secs, err := strconv.ParseFloat(stepStr, 64); err == nil {
			step = time.Duration(secs * float64(time.Second))
		} else {
			step, err = time.ParseDuration(stepStr)
			if err != nil {
				return time.Time{}, time.Time{}, 0, fmt.Errorf("invalid step: %w", err)
			}
		}
	}

	return start, end, step, nil
}

func parseTime(s string) (time.Time, error) {
	if s == "" {
		return time.Now(), nil
	}
	// Try as Unix timestamp (seconds, possibly with decimals)
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		sec := int64(f)
		nsec := int64((f - float64(sec)) * 1e9)
		return time.Unix(sec, nsec), nil
	}
	// Try RFC3339
	return time.Parse(time.RFC3339, s)
}

func formatValue(v float64) string {
	if v == float64(int64(v)) {
		return strconv.FormatInt(int64(v), 10)
	}
	return strconv.FormatFloat(v, 'f', -1, 64)
}
