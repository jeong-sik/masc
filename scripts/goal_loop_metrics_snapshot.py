#!/usr/bin/env python3
"""Build GOAL LOOP Verify metric snapshot JSON from Prometheus text.

The Verify pipeline intentionally consumes a small JSON snapshot instead of
shelling out to Prometheus. This helper makes that snapshot reproducible from a
runtime ``/metrics`` scrape while leaving non-Prometheus evidence explicit via
``--set key=value``.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


PROMETHEUS_LINE_RE = re.compile(
    r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(?P<labels>[^}]*)\})?\s+"
    r"(?P<value>[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|NaN|[+-]?Inf)"
    r"(?:\s+\d+)?$"
)
LABEL_RE = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"')


@dataclass(frozen=True)
class Sample:
    name: str
    labels: dict[str, str]
    value: float


def parse_value(raw: str) -> float:
    if raw == "NaN":
        return float("nan")
    if raw in {"Inf", "+Inf"}:
        return float("inf")
    if raw == "-Inf":
        return float("-inf")
    return float(raw)


def unescape_label(raw: str) -> str:
    return raw.replace(r"\\", "\\").replace(r"\"", '"').replace(r"\n", "\n")


def parse_labels(raw: str | None) -> dict[str, str]:
    if not raw:
        return {}
    labels: dict[str, str] = {}
    for match in LABEL_RE.finditer(raw):
        labels[match.group(1)] = unescape_label(match.group(2))
    return labels


def parse_prometheus_text(text: str) -> list[Sample]:
    samples: list[Sample] = []
    for line_no, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = PROMETHEUS_LINE_RE.match(line)
        if match is None:
            raise ValueError(f"invalid Prometheus sample line {line_no}: {raw_line}")
        samples.append(
            Sample(
                name=match.group("name"),
                labels=parse_labels(match.group("labels")),
                value=parse_value(match.group("value")),
            )
        )
    return samples


def sum_metric(samples: list[Sample], name: str) -> float | None:
    values = [sample.value for sample in samples if sample.name == name]
    if not values:
        return None
    return sum(values)


def keeper_turn_success_rate(samples: list[Sample]) -> float | None:
    turn_samples = [
        sample for sample in samples if sample.name == "masc_keeper_turns_total"
    ]
    if not turn_samples:
        return None
    total = sum(sample.value for sample in turn_samples)
    if total <= 0:
        return None
    success = sum(
        sample.value
        for sample in turn_samples
        if sample.labels.get("outcome") == "success"
    )
    return success / total


def histogram_quantile_from_buckets(
    samples: list[Sample],
    *,
    bucket_name: str,
    quantile: float,
) -> float | None:
    buckets: dict[float, float] = {}
    for sample in samples:
        if sample.name != bucket_name:
            continue
        raw_le = sample.labels.get("le")
        if raw_le is None:
            continue
        le = float("inf") if raw_le == "+Inf" else float(raw_le)
        buckets[le] = buckets.get(le, 0.0) + sample.value
    if not buckets:
        return None
    sorted_buckets = sorted(buckets.items(), key=lambda item: item[0])
    total = sorted_buckets[-1][1]
    if total <= 0:
        return None
    target = total * quantile
    previous_le = 0.0
    previous_count = 0.0
    for le, count in sorted_buckets:
        if count < target:
            if le != float("inf"):
                previous_le = le
            previous_count = count
            continue
        if le == float("inf"):
            return previous_le
        bucket_count = count - previous_count
        if bucket_count <= 0:
            return le
        fraction = (target - previous_count) / bucket_count
        return previous_le + ((le - previous_le) * fraction)
    return sorted_buckets[-1][0]


def parse_override(raw: str) -> tuple[str, float]:
    if "=" not in raw:
        raise ValueError(f"expected KEY=VALUE override, got {raw!r}")
    key, value = raw.split("=", 1)
    key = key.strip()
    if not key:
        raise ValueError(f"empty metric key in override {raw!r}")
    return key, float(value)


def build_snapshot(samples: list[Sample], overrides: list[str]) -> dict[str, Any]:
    metrics: dict[str, float] = {}

    derived = {
        "keeper_turn_success_rate": keeper_turn_success_rate(samples),
        "keeper_skipping_turn_rate_5m": sum_metric(
            samples, "masc_keeper_semaphore_wait_timeout_total"
        ),
        "pricing_catalog_miss_total": sum_metric(
            samples, "masc_pricing_catalog_miss_total"
        ),
        "persistence_utf8_repair_total": sum_metric(
            samples, "masc_persistence_utf8_repair_total"
        ),
        "admission_queue_depth": sum_metric(samples, "masc_inference_queue_depth"),
        "admission_queue_wait_ms": (
            sum_metric(samples, "masc_inference_queue_wait_seconds_sum") or 0.0
        )
        * 1000.0,
        "dashboard_snapshot_latency_p99": histogram_quantile_from_buckets(
            samples,
            bucket_name="masc_dashboard_snapshot_latency_seconds_bucket",
            quantile=0.99,
        ),
    }
    if sum_metric(samples, "masc_inference_queue_wait_seconds_sum") is None:
        derived["admission_queue_wait_ms"] = None

    for key, value in derived.items():
        if value is not None:
            metrics[key] = value

    for raw in overrides:
        key, value = parse_override(raw)
        metrics[key] = value

    return {
        "schema_version": 1,
        "snapshot_kind": "goal_loop_verify_metrics",
        "metrics": metrics,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "prometheus_text",
        nargs="?",
        help="Prometheus text file. Reads stdin when omitted.",
    )
    parser.add_argument(
        "--set",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help=(
            "Set a snapshot metric that cannot be derived from Prometheus text, "
            "for example orient_recheck_still_present=0."
        ),
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.prometheus_text:
        text = Path(args.prometheus_text).read_text(encoding="utf-8")
    else:
        text = sys.stdin.read()
    snapshot = build_snapshot(parse_prometheus_text(text), args.set)
    print(
        json.dumps(
            snapshot,
            ensure_ascii=False,
            sort_keys=True,
            indent=2 if args.pretty else None,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
