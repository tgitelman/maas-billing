package handlers

import (
	"fmt"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/logql"
	"github.com/opendatahub-io/maas-billing-pocs/loki-sql-adaptor/internal/translator"
)

// Query handles GET /loki/api/v1/query (instant queries)
func (h *Handler) Query(c *gin.Context) {
	query := c.Query("query")
	if query == "" {
		errorResponse(c, 400, "query parameter is required")
		return
	}

	timeStr := c.Query("time")
	var evalTime time.Time
	if timeStr != "" {
		var err error
		evalTime, err = parseTime(timeStr)
		if err != nil {
			errorResponse(c, 400, fmt.Sprintf("invalid time: %v", err))
			return
		}
	} else {
		evalTime = time.Now()
	}

	parsed, err := logql.Parse(query)
	if err != nil {
		errorResponse(c, 400, fmt.Sprintf("failed to parse LogQL: %v", err))
		return
	}

	// For instant queries, use a 1-hour lookback by default (matches Perses dashboard duration)
	start := evalTime.Add(-1 * time.Hour)
	tr := translator.TimeRange{Start: start, End: evalTime}

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
		h.handleScalarResult(c, rows, evalTime)
	case "vector":
		h.handleVectorResult(c, rows, translated.GroupBy, evalTime)
	default:
		// For instant queries, matrix doesn't apply — treat as vector
		h.handleVectorResult(c, rows, translated.GroupBy, evalTime)
	}
}
