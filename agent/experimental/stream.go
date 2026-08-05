// Package experimental contains work-in-progress features not yet ready
// for a stable release. API may change without notice.
package experimental

// StreamBatch compresses a slice of metric points into a single message.
type StreamBatch struct {
	Algo  string   `json:"algo"`
	Points []Point `json:"points"`
}

type Point struct {
	CPU    float64 `json:"cpu"`
	Memory float64 `json:"mem"`
}
