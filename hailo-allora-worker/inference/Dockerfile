FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    libopencv-dev \
    python3-opencv \
    curl \
    && rm -rf /var/lib/apt/lists/*

# hailo_platform wheel is installed from the HailoRT release package.
# On the Pi, install system-wide HailoRT first, then this wheel installs the
# Python bindings that link against the system libhailort.so.
# The package is not on PyPI — it ships with the Hailo SW Suite.
# Mount or COPY the .whl into the build context and reference it here:
#   COPY hailort-*.whl /tmp/
#   RUN pip install /tmp/hailort-*.whl
# For now we install the rest of the deps and expect hailo_platform to be
# available via the host system mount (/usr/lib/python3/dist-packages).

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY inference_service.py .

RUN mkdir -p /data

CMD ["python", "-u", "-m", "uvicorn", "inference_service:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
