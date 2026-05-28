package handlers

import "github.com/gin-gonic/gin"

// Loki API response format: https://grafana.com/docs/loki/latest/reference/loki-http-api/

type LokiResponse struct {
	Status string   `json:"status"`
	Data   LokiData `json:"data"`
}

type LokiData struct {
	ResultType string      `json:"resultType"`
	Result     interface{} `json:"result"`
}

type MatrixResult struct {
	Metric map[string]string `json:"metric"`
	Values [][]interface{}   `json:"values"`
}

type VectorResult struct {
	Metric map[string]string `json:"metric"`
	Value  []interface{}     `json:"value"`
}

func successResponse(c *gin.Context, resultType string, result interface{}) {
	c.JSON(200, LokiResponse{
		Status: "success",
		Data: LokiData{
			ResultType: resultType,
			Result:     result,
		},
	})
}

func errorResponse(c *gin.Context, status int, msg string) {
	c.JSON(status, gin.H{
		"status": "error",
		"error":  msg,
	})
}
