// Package utils provides utility functions for the hub.
package utils

import "os"

// GetEnv retrieves an environment variable with a "BIGBROTHER_HUB_" prefix, or falls back to the unprefixed key.
func GetEnv(key string) (value string, exists bool) {
	if value, exists = os.LookupEnv("BIGBROTHER_HUB_" + key); exists {
		return value, exists
	}
	return os.LookupEnv(key)
}
