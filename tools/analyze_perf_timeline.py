#!/usr/bin/env python3
"""Summarize completed engine/Dart timeline spans, preserving their distinct meaning"""

import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path


def analyze(path):
    data = json.loads(path.read_text())
    data = data.get("result", data)
    events = data["traceEvents"]
    pending = defaultdict(list)
    durations = defaultdict(list)
    budgets = Counter()
    unmatched_ends = 0
    for event in sorted(events, key=lambda e: e.get("ts", 0)):
        name, phase = event.get("name"), event.get("ph")
        if name == "PlatformVsync" and phase == "B":
            args = event.get("args", {})
            if "frame_target_time" in args and "frame_start_time" in args:
                us = int(args["frame_target_time"]) - int(args["frame_start_time"])
                if us > 0:
                    budgets[round(us / 1000, 2)] += 1
        key = (event.get("pid"), None if phase in ("b", "e") else event.get("tid"), name,
               event.get("id") if phase in ("b", "e") else None)
        if phase in ("B", "b"):
            pending[key].append(event["ts"])
        elif phase in ("E", "e"):
            if pending[key]:
                durations[name].append((event["ts"] - pending[key].pop()) / 1000)
            else:
                unmatched_ends += 1
        elif phase == "X":
            durations[name].append(event["dur"] / 1000)
    spans = {}
    for name, values in durations.items():
        values.sort()
        n = len(values)
        spans[name] = {"n": n, "p50_ms": values[math.ceil(n * .5) - 1],
                       "p95_ms": values[math.ceil(n * .95) - 1], "max_ms": values[-1],
                       "sum_ms": round(sum(values), 3)}
    return {"timeline": str(path), "event_count": len(events),
            "possible_ring_wrap": len(events) >= 30000,
            "engine_vsync_budgets_ms": dict(budgets),
            "unmatched_starts": sum(map(len, pending.values())),
            "unmatched_ends": unmatched_ends,
            "spans": spans,
            "limits": ["Spans overlap; inclusive times must not be added across names",
                       "Dart Frame and GPURasterizer::Draw are timeline spans, not identical to FrameTiming fields",
                       "Only completed spans retained in the VM ring buffer are summarized",
                       "No percentile is inferred from batched trace percentiles"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("timelines", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.timelines:
        result = analyze(path)
        path.with_name("timeline-summary.json").write_text(json.dumps(result, indent=2) + "\n")
        names = ("Frame", "GPURasterizer::Draw", "LayerTree::Paint", "SurfaceFrame::Submit")
        print(json.dumps({k: v for k, v in result.items() if k != "spans"}, indent=2))
        print(json.dumps({name: result["spans"].get(name) for name in names}, indent=2))


if __name__ == "__main__":
    main()
