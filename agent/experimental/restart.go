package experimental

// RestartPolicy experiments with backoff strategies for agent restarts.
type RestartPolicy struct {
	MaxBackoffSec int
}
