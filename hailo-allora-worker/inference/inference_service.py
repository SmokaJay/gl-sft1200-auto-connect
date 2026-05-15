import base64
import logging
import sqlite3
import time
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Optional

import cv2
import numpy as np
import requests
from fastapi import FastAPI, HTTPException
from hailo_platform import (
    ConfigureParams,
    FormatType,
    HEF,
    HailoStreamInterface,
    InferVStreams,
    InputVStreamParams,
    OutputVStreamParams,
    VDevice,
)
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

MODEL_PATH = "/models/efficientnet_b0_quantized.hef"
DB_PATH = "/data/inference_metrics.db"
IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


class _State:
    vdevice: Optional[VDevice] = None
    network_group = None
    input_vstreams_params = None
    output_vstreams_params = None
    model_name: str = "efficientnet_b0"


state = _State()


def _init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT,
            image_size INTEGER,
            preprocess_ms REAL,
            inference_ms REAL,
            class_id INTEGER,
            confidence REAL,
            error TEXT
        )
    """)
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
    conn.close()


def _log_metric(image_size, preprocess_ms, inference_ms, class_id, confidence, error=None):
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.execute(
            "INSERT INTO metrics (timestamp, image_size, preprocess_ms, inference_ms, class_id, confidence, error) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (datetime.now().isoformat(), image_size, preprocess_ms, inference_ms, class_id, confidence, error),
        )
        conn.commit()
        conn.close()
    except Exception as e:
        logger.warning(f"Failed to log metric: {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    _init_db()
    hef = HEF(MODEL_PATH)
    state.vdevice = VDevice()
    configure_params = ConfigureParams.create_from_hef(hef, interface=HailoStreamInterface.PCIe)
    network_groups = state.vdevice.configure(hef, configure_params)
    state.network_group = network_groups[0]
    state.input_vstreams_params = InputVStreamParams.make(
        state.network_group, quantized=False, format_type=FormatType.FLOAT32
    )
    state.output_vstreams_params = OutputVStreamParams.make(
        state.network_group, quantized=False, format_type=FormatType.FLOAT32
    )
    logger.info(f"Hailo device ready, model loaded: {MODEL_PATH}")
    yield
    if state.vdevice:
        state.vdevice.release()
        logger.info("Hailo device released")


app = FastAPI(title="Hailo Inference Service", version="1.0.0", lifespan=lifespan)


class ImageInput(BaseModel):
    image_url: Optional[str] = Field(None, description="URL to fetch image from")
    image_base64: Optional[str] = Field(None, description="Base64-encoded image bytes")


class InferenceOutput(BaseModel):
    class_id: int
    confidence: float
    logits: list[float]
    inference_time_ms: float
    model: str


def _preprocess(image: np.ndarray) -> np.ndarray:
    image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    image = cv2.resize(image, (224, 224), interpolation=cv2.INTER_LINEAR)
    image = image.astype(np.float32) / 255.0
    image = (image - IMAGENET_MEAN) / IMAGENET_STD
    return np.expand_dims(image, axis=0)  # (1, 224, 224, 3)


def _load_image(input_data: ImageInput) -> np.ndarray:
    if input_data.image_base64:
        buf = base64.b64decode(input_data.image_base64)
    elif input_data.image_url:
        resp = requests.get(input_data.image_url, timeout=5)
        resp.raise_for_status()
        buf = resp.content
    else:
        raise ValueError("Provide image_url or image_base64")
    arr = np.frombuffer(buf, np.uint8)
    image = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError("Failed to decode image")
    return image


@app.post("/predict", response_model=InferenceOutput)
async def predict(input_data: ImageInput):
    if state.vdevice is None:
        raise HTTPException(status_code=503, detail="Hailo device not ready")

    t0 = time.time()
    try:
        image = _load_image(input_data)
        image_size = image.size
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Image load error: {e}")

    t1 = time.time()
    preprocess_ms = (t1 - t0) * 1000

    try:
        tensor = _preprocess(image)
        input_name = list(state.input_vstreams_params.keys())[0]
        output_name = list(state.output_vstreams_params.keys())[0]

        with InferVStreams(
            state.network_group,
            state.input_vstreams_params,
            state.output_vstreams_params,
        ) as infer_pipeline:
            with state.network_group.activate():
                infer_pipeline.send({input_name: tensor})
                output = infer_pipeline.recv()

        logits = output[output_name][0].tolist()
        class_id = int(np.argmax(logits))
        confidence = float(np.max(logits))

    except Exception as e:
        _log_metric(image_size, preprocess_ms, 0, -1, 0.0, str(e))
        logger.error(f"Inference error: {e}")
        raise HTTPException(status_code=500, detail=f"Inference error: {e}")

    inference_ms = (time.time() - t1) * 1000
    _log_metric(image_size, preprocess_ms, inference_ms, class_id, confidence)

    return InferenceOutput(
        class_id=class_id,
        confidence=confidence,
        logits=logits,
        inference_time_ms=preprocess_ms + inference_ms,
        model=state.model_name,
    )


@app.get("/health")
async def health():
    return {
        "status": "ok" if state.vdevice is not None else "degraded",
        "model": state.model_name,
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000, workers=1)
