import sqlite3
import time

from prometheus_client import Counter, Gauge, Histogram, start_http_server

DB_PATH = "/data/inference_metrics.db"

inference_total = Counter("inference_total", "Total inferences", ["topic"])
inference_latency = Histogram(
    "inference_latency_ms",
    "Inference latency in ms",
    buckets=[10, 20, 50, 100, 150, 200, 500],
)
submission_total = Counter("submissions_total", "Total chain submissions", ["topic", "status"])
reputation_score = Gauge("reputation_score", "Worker reputation score", ["topic"])
earnings_allo = Gauge("earnings_allo_total", "Total ALLO earned", ["topic"])


def _update():
    try:
        conn = sqlite3.connect(DB_PATH)

        for row in conn.execute(
            "SELECT COUNT(*), AVG(inference_ms) FROM metrics WHERE error IS NULL"
        ).fetchall():
            count, avg_ms = row
            if avg_ms:
                inference_latency.observe(avg_ms)

        conn.close()
    except Exception as e:
        print(f"Metrics update error: {e}")


if __name__ == "__main__":
    start_http_server(8001)
    print("Prometheus exporter running on :8001")
    while True:
        _update()
        time.sleep(60)
