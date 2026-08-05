package experimental

// NewStreamBatch builds a batch from raw metric values.
func NewStreamBatch(cpu, mem float64) *StreamBatch {
	return &StreamBatch{Algo: "zstd", Points: []Point{{CPU: cpu, Memory: mem}}}
}
