#!/bin/bash
# Weekly retraining pipeline — runs on Windows dev machine (RTX 3050).
# Triggered manually or via Task Scheduler every Sunday at 02:00.
set -euo pipefail

PI_HOST="${PI_HOST:-pi@192.168.1.100}"
MODEL_DIR="${MODEL_DIR:-C:/models}"
WEEK=$(date +%Y_week_%V)
PREV_ACC_FILE="$MODEL_DIR/prev_accuracy.txt"

log() { echo "[$(date +%T)] $*"; }

log "=== Weekly retrain: $WEEK ==="

# 1. Pull mispredictions from Pi
log "Syncing mispredictions from Pi..."
scp "$PI_HOST:/data/mispredictions.csv" /tmp/mispredictions_raw.csv

# 2. Label (edit /tmp/mispredictions_raw.csv manually or via active-learning tool)
log "Label new data, then press Enter to continue..."
read -r

# 3. Merge with existing dataset
log "Merging datasets..."
python train/merge_datasets.py \
    "$MODEL_DIR/training_data.csv" \
    /tmp/mispredictions_raw.csv \
    "$MODEL_DIR/training_data_updated.csv"

# 4. Fine-tune (transfer learning from ImageNet checkpoint)
log "Training EfficientNet-B0..."
python train/train_efficientnet.py \
    --data "$MODEL_DIR/training_data_updated.csv" \
    --epochs 20 \
    --batch-size 64 \
    --lr 1e-4 \
    --output "$MODEL_DIR/efficientnet_b0_$WEEK.pt"

# 5. Quantization-aware training
log "QAT fine-tune..."
python train/qat_fine_tune.py \
    --model "$MODEL_DIR/efficientnet_b0_$WEEK.pt" \
    --data "$MODEL_DIR/training_data_updated.csv" \
    --epochs 5 \
    --output "$MODEL_DIR/efficientnet_b0_${WEEK}_qat.pt"

# 6. Evaluate on held-out test set
log "Evaluating..."
python train/evaluate.py \
    --model "$MODEL_DIR/efficientnet_b0_${WEEK}_qat.pt" \
    --data "$MODEL_DIR/test_set.csv" \
    --output /tmp/eval_$WEEK.json

NEW_ACC=$(python -c "import json; print(json.load(open('/tmp/eval_$WEEK.json'))['accuracy'])")
PREV_ACC=$(cat "$PREV_ACC_FILE" 2>/dev/null || echo "0")
log "Accuracy: previous=$PREV_ACC  new=$NEW_ACC"

if python -c "exit(0 if float('$NEW_ACC') > float('$PREV_ACC') else 1)"; then
    log "Accuracy improved — exporting to Hailo HEF..."

    # 7. Export: PyTorch → ONNX → Hailo HEF (requires Hailo Dataflow Compiler)
    python train/export_to_hailo.py \
        --model "$MODEL_DIR/efficientnet_b0_${WEEK}_qat.pt" \
        --output "$MODEL_DIR/efficientnet_b0_$WEEK.hef" \
        --target hailo8

    # 8. Deploy to Pi
    log "Deploying to Pi..."
    scp "$MODEL_DIR/efficientnet_b0_$WEEK.hef" \
        "$PI_HOST:/home/pi/models/efficientnet_b0_quantized.hef"

    ssh "$PI_HOST" "docker restart hailo-inference"
    sleep 15
    ssh "$PI_HOST" "curl -sf http://localhost:8000/health" || { log "ERROR: Health check failed after deploy"; exit 1; }

    echo "$NEW_ACC" > "$PREV_ACC_FILE"
    log "Deployed successfully."
else
    log "No accuracy improvement — keeping current model."
fi

log "=== Done ==="
