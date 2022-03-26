package http

import (
	"net/http"
	"net/http/httptest"
	"path"
	"testing"

	"github.com/influxdata/influxdb/v2/kit/platform"
	"github.com/influxdata/influxdb/v2/kit/prom"
	"github.com/influxdata/influxdb/v2/kit/prom/promtest"
	"github.com/influxdata/influxdb/v2/pkg/testttp"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap/zaptest"
)

func TestMetrics(t *testing.T) {
	labels := []string{"handler", "method", "path", "status", "response_code", "user_agent"}

	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			w.WriteHeader(http.StatusOK)
			return
		}

		if r.URL.Path == "/serverError" {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		if r.URL.Path == "/redirect" {
			w.WriteHeader(http.StatusPermanentRedirect)
			return
		}

		w.WriteHeader(http.StatusNotFound)
	})

	tests := []struct {
		name          string
		reqPath       string
		wantCount     int
		labelResponse string
		labelStatus   string
	}{
		{
			name:          "counter increments on OK (2XX) ",
			reqPath:       "/",
			wantCount:     1,
			labelResponse: "200",
			labelStatus:   "2XX",
		},
		{
			name:      "counter does not increment on not found (4XX)",
			reqPath:   "/badpath",
			wantCount: 0,
		},
		{
			name:          "counter increments on server error (5XX)",
			reqPath:       "/serverError",
			wantCount:     1,
			labelResponse: "500",
			labelStatus:   "5XX",
		},
		{
			name:      "counter does not increment on redirect (3XX)",
			reqPath:   "/redirect",
			wantCount: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			counter := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "counter"}, labels)
			hist := prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "hist"}, labels)
			reg := prom.NewRegistry(zaptest.NewLogger(t))
			reg.MustRegister(counter, hist)

			metricsMw := Metrics("testing", counter, hist)
			svr := metricsMw(nextHandler)
			r := httptest.NewRequest("GET", tt.reqPath, nil)
			w := httptest.NewRecorder()
			svr.ServeHTTP(w, r)

			mfs := promtest.MustGather(t, reg)
			m := promtest.FindMetric(mfs, "counter", map[string]string{
				"handler":       "testing",
				"method":        "GET",
				"path":          tt.reqPath,
				"response_code": tt.labelResponse,
				"status":        tt.labelStatus,
				"user_agent":    "unknown",
			})

			if tt.wantCount == 0 {
				require.Nil(t, m)
				return
			}

			require.Equal(t, tt.wantCount, int(m.Counter.GetValue()))
		})
	}
}

func Test_normalizePath(t *testing.T) {
	tests := []struct {
		name     string
		path     string
		expected string
	}{
		{
			name:     "1",
			path:     path.Join("/api/v2/organizations", platform.ID(2).String()),
			expected: "/api/v2/organizations/:id",
		},
		{
			name:     "2",
			path:     "/api/v2/organizations",
			expected: "/api/v2/organizations",
		},
		{
			name:     "3",
			path:     "/",
			expected: "/",
		},
		{
			name:     "4",
			path:     path.Join("/api/v2/organizations", platform.ID(2).String(), "users", platform.ID(3).String()),
			expected: "/api/v2/organizations/:id/users/:id",
		},
		{
			name:     "5",
			path:     "/838442d56d.svg",
			expected: "/" + fileSlug + ".svg",
		},
		{
			name:     "6",
			path:     "/838442d56d.svg/extra",
			expected: "/838442d56d.svg/extra",
		},
		{
			name:     "7",
			path:     "/api/v2/restore/shards/1001",
			expected: path.Join("/api/v2/restore/shards/", shardSlug),
		},
		{
			name:     "8",
			path:     "/api/v2/restore/shards/1001/extra",
			expected: path.Join("/api/v2/restore/shards/", shardSlug, "extra"),
		},
		{
			name:     "9",
			path:     "/api/v2/backup/shards/1005",
			expected: path.Join("/api/v2/backup/shards/", shardSlug),
		},
		{
			name:     "10",
			path:     "/api/v2/backup/shards/1005/extra",
			expected: path.Join("/api/v2/backup/shards/", shardSlug, "extra"),
		},
		{
			name:     "11",
			path:     "/35bb8d560d.ttf",
			expected: "/" + fileSlug + ".ttf",
		},
		{
			name:     "12",
			path:     "/35bb8d560d.woff",
			expected: "/" + fileSlug + ".woff",
		},
		{
			name:     "13",
			path:     "/35bb8d560d.eot",
			expected: "/" + fileSlug + ".eot",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			actual := normalizePath(tt.path)
			assert.Equal(t, tt.expected, actual)
		})
	}
}

func TestCors(t *testing.T) {
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("nextHandler"))
	})

	tests := []struct {
		name            string
		method          string
		headers         []string
		expectedStatus  int
		expectedHeaders map[string]string
	}{
		{
			name:           "OPTIONS without Origin",
			method:         "OPTIONS",
			expectedStatus: http.StatusMethodNotAllowed,
		},
		{
			name:           "OPTIONS with Origin",
			method:         "OPTIONS",
			headers:        []string{"Origin", "http://myapp.com"},
			expectedStatus: http.StatusNoContent,
		},
		{
			name:           "GET with Origin",
			method:         "GET",
			headers:        []string{"Origin", "http://anotherapp.com"},
			expectedStatus: http.StatusOK,
			expectedHeaders: map[string]string{
				"Access-Control-Allow-Origin": "http://anotherapp.com",
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svr := SkipOptions(SetCORS(nextHandler))

			testttp.
				HTTP(t, tt.method, "/", nil).
				Headers("", "", tt.headers...).
				Do(svr).
				ExpectStatus(tt.expectedStatus).
				ExpectHeaders(tt.expectedHeaders)
		})
	}
}
