#!/usr/bin/env python3
"""
Converts the OmniParser YOLOv8-nano icon detector to CoreML.

Requirements:
    pip install ultralytics coremltools

Usage:
    python3 scripts/convert_omniparser_to_coreml.py \
        --weights /Users/osmond/OmniParser/weights/icon_detect/model.pt \
        --output LumiAgent/Resources/Models/icon_detect.mlpackage

The resulting .mlpackage is bundled by SPM (.copy resource rule in Package.swift)
and loaded at runtime by LocalScreenParser.swift via Bundle.module.
"""
import argparse
import shutil
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert OmniParser YOLOv8-nano icon_detect weights to CoreML."
    )
    parser.add_argument(
        "--weights",
        required=True,
        type=Path,
        help="Path to model.pt (e.g. OmniParser/weights/icon_detect/model.pt)",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Destination path for icon_detect.mlpackage",
    )
    args = parser.parse_args()

    if not args.weights.exists():
        print(f"ERROR: weights file not found: {args.weights}", file=sys.stderr)
        sys.exit(1)

    try:
        from ultralytics import YOLO  # noqa: PLC0415
    except ImportError:
        print(
            "ERROR: required packages missing.\n"
            "Install them with:  pip install ultralytics coremltools",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Loading weights from: {args.weights}")
    model = YOLO(str(args.weights))

    print("Exporting to CoreML (this may take a few minutes)…")
    # nms=True bakes NMS into the CoreML graph so VNCoreMLRequest returns
    # VNRecognizedObjectObservation results directly — no manual decode needed.
    export_path = model.export(
        format="coreml",
        imgsz=1280,
        nms=True,
        conf=0.25,
        iou=0.45,
        half=False,
        device="cpu",
    )

    src = Path(export_path)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        shutil.rmtree(args.output)
    src.rename(args.output)
    print(f"Saved to: {args.output}")
    print(
        "\nNext steps:\n"
        "  1. Build the Swift package — SPM will bundle the model automatically.\n"
        "  2. Run the app and trigger an agent screen action.\n"
        "  3. The log should show 'LocalParser (CoreML) detected N UI element(s)'."
    )


if __name__ == "__main__":
    main()
