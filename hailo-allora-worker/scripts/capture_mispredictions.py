"""
Called after each epoch when ground truth is revealed.
Pass image_url, predicted values, and actual class to log mispredictions
for use in the weekly retraining cycle.
"""

import csv
import sqlite3
from datetime import datetime
from pathlib import Path

DB_PATH = "/data/inference_metrics.db"
CSV_PATH = "/data/mispredictions.csv"


def _ensure_table(conn: sqlite3.Connection):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS mispredictions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT,
            image_url TEXT,
            predicted_class INTEGER,
            predicted_confidence REAL,
            actual_class INTEGER,
            topic_id INTEGER
        )
    """)
    conn.commit()


def log_misprediction(
    image_url: str,
    predicted_class: int,
    predicted_confidence: float,
    actual_class: int,
    topic_id: int = 5,
):
    conn = sqlite3.connect(DB_PATH)
    _ensure_table(conn)
    conn.execute(
        "INSERT INTO mispredictions "
        "(timestamp, image_url, predicted_class, predicted_confidence, actual_class, topic_id) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (datetime.now().isoformat(), image_url, predicted_class, predicted_confidence, actual_class, topic_id),
    )
    conn.commit()
    conn.close()

    with open(CSV_PATH, "a", newline="") as f:
        csv.writer(f).writerow([image_url, predicted_class, predicted_confidence, actual_class, topic_id])


def analyze_mispredictions() -> dict:
    conn = sqlite3.connect(DB_PATH)
    _ensure_table(conn)

    total = conn.execute("SELECT COUNT(*) FROM mispredictions").fetchone()[0]
    avg_conf = conn.execute("SELECT AVG(predicted_confidence) FROM mispredictions").fetchone()[0] or 0.0
    by_topic = {
        row[0]: row[1]
        for row in conn.execute(
            "SELECT topic_id, COUNT(*) FROM mispredictions GROUP BY topic_id"
        ).fetchall()
    }
    conn.close()

    return {"total": total, "avg_confidence": round(avg_conf, 4), "by_topic": by_topic}


if __name__ == "__main__":
    stats = analyze_mispredictions()
    print(f"Total mispredictions: {stats['total']}")
    print(f"Avg confidence on wrong predictions: {stats['avg_confidence']:.3f}")
    if stats["avg_confidence"] > 0.6:
        print("  WARNING: Model is overconfident on wrong answers — prioritise retraining")
    print(f"By topic: {stats['by_topic']}")
