package handlers

import "github.com/gin-gonic/gin"

// Labels handles GET /loki/api/v1/labels
func (h *Handler) Labels(c *gin.Context) {
	labels, err := h.store.Labels(c.Request.Context())
	if err != nil {
		errorResponse(c, 500, err.Error())
		return
	}

	c.JSON(200, gin.H{
		"status": "success",
		"data":   labels,
	})
}

// LabelValues handles GET /loki/api/v1/label/:name/values
func (h *Handler) LabelValues(c *gin.Context) {
	name := c.Param("name")
	if name == "" {
		errorResponse(c, 400, "label name is required")
		return
	}

	values, err := h.store.LabelValues(c.Request.Context(), name)
	if err != nil {
		errorResponse(c, 500, err.Error())
		return
	}

	c.JSON(200, gin.H{
		"status": "success",
		"data":   values,
	})
}
