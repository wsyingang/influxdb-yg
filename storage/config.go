package storage

import (
	"time"

	"github.com/influxdata/influxdb/v2/tsdb"
	"github.com/influxdata/influxdb/v2/v1/services/precreator"
	"github.com/influxdata/influxdb/v2/v1/services/retention"
)

// DefaultWriteTimeout is the default timeout for a complete write to succeed.
const DefaultWriteTimeout = 10 * time.Second

// Config holds the configuration for an Engine.
type Config struct {
	Data         tsdb.Config
	WriteTimeout time.Duration

	RetentionService retention.Config
	PrecreatorConfig precreator.Config
}

// NewConfig initialises a new config for an Engine.
func NewConfig() Config {
	return Config{
		Data:             tsdb.NewConfig(),
		WriteTimeout:     DefaultWriteTimeout,
		RetentionService: retention.NewConfig(),
		PrecreatorConfig: precreator.NewConfig(),
	}
}
