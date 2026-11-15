#!/usr/bin/env bash
# Builds tools/pipeline_benchmark.swift against the real app files and runs it.
#   tools/run_pipeline_benchmark.sh             # live camera
#   tools/run_pipeline_benchmark.sh face.jpg    # still photo
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="build/benchmark"
mkdir -p "$OUT"

# The benchmark finds the model next to its executable (Bundle.main for a command-line tool).
if [[ ! -d "$OUT/ArcFace.mlmodelc" || MacFace/Models/ArcFace.mlpackage -nt "$OUT/ArcFace.mlmodelc" ]]; then
    rm -rf "$OUT/ArcFace.mlmodelc"
    xcrun coremlcompiler compile MacFace/Models/ArcFace.mlpackage "$OUT" >/dev/null
fi

# Top-level code is only allowed in a file named main.swift.
cp tools/pipeline_benchmark.swift "$OUT/main.swift"
xcrun swiftc -O -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -o "$OUT/pipeline_benchmark" \
    MacFace/CameraFrame.swift \
    MacFace/CameraFormatSelector.swift \
    MacFace/FaceDetector.swift \
    MacFace/FaceAligner.swift \
    MacFace/FaceEmbedder.swift \
    MacFace/ArcFaceEmbedder.swift \
    MacFace/Liveness/DeviceBezelDetector.swift \
    MacFace/Liveness/GlareCueExtractor.swift \
    MacFace/Liveness/GlareCue.swift \
    MacFace/Liveness/LandmarkGeometry.swift \
    "$OUT/main.swift"

"$OUT/pipeline_benchmark" "$@"
