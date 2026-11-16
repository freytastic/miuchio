#!/usr/bin/env python3
"""Capture one bounded, repeatable interaction on an already-open test phone

python3 tools/capture_perf.py --serial SERIAL --label note8 --scenario grid --seconds 20
Optional --actions JSON runs [{"tap": [x, y], "wait": 2}, ...]
Coordinates must be calibrated from that phone's current screen before running
"""

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urlencode, urlparse
from urllib.request import urlopen


PACKAGE = "com.freytastic.miuchio"
ROOT = Path(__file__).resolve().parents[1]
EVENT = re.compile(r"miuchio\.trace\|(\d+)\|t=(\d+)\|([^|\s]+)(?:\|dur=(\d+))?(.*)")
FIELD = re.compile(r"(\w+)=(\S+)")


def adb(serial, *args, timeout=20):
    result = subprocess.run(["adb", "-s", serial, *args], capture_output=True,
                            text=True, timeout=timeout, check=True)
    return result.stdout.strip()


def wait_pid(serial):
    # Some OEMs return am start -W while the launcher is still resuming
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            pid = adb(serial, "shell", "pidof", PACKAGE)
            if pid.isdigit():
                return pid
        except subprocess.CalledProcessError:
            pass
        time.sleep(0.25)
    raise RuntimeError("App process missing 15 seconds after relaunch")


def vm_call(base, method, **params):
    url = base.rstrip("/") + "/" + method
    if params:
        url += "?" + urlencode(params)
    with urlopen(url, timeout=15) as response:
        data = json.load(response)
    if "error" in data:
        raise RuntimeError(f"VM service {method}: {data['error']}")
    return data["result"]


def read_state(serial):
    commands = {
        "model": "getprop ro.product.model",
        "android": "getprop ro.build.version.release",
        "soc": "getprop ro.board.platform",
        "size": "wm size",
        "density": "wm density",
        "battery": "dumpsys battery | head -26",
        "thermal": "dumpsys thermalservice | head -45",
        "display": "dumpsys display | grep -E 'mActiveModeId|mRefreshRate|renderFrameRate|DisplayDeviceInfo'",
        "power": "dumpsys power | grep -E 'mWakefulness=|mIsPowered=|mLowPowerModeEnabled='",
        "foreground": "dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity'",
        "memory": f"dumpsys meminfo {PACKAGE}",
        "low_power": "settings get global low_power",
    }
    state = {}
    for name, command in commands.items():
        try:
            state[name] = adb(serial, "shell", command)
        except (subprocess.SubprocessError, OSError) as exc:
            state[name] = {"error": str(exc)}
    return state


def summarize(log):
    screens = defaultdict(lambda: {"frames": 0, "over_budget": 0, "late_start": 0,
                                   "build_max_ms": 0., "raster_max_ms": 0.,
                                   "raster_sum_ms": 0., "budgets_ms": set()})
    blocks, spans, firsts, failures = [], defaultdict(list), [], []
    seen = set()
    trace_count = 0
    for line in log.splitlines():
        match = EVENT.search(line)
        if not match:
            continue
        seq, stamp, name, duration, rest = match.groups()
        key = (seq, stamp)
        if key in seen:
            continue
        seen.add(key)
        trace_count += 1
        fields = dict(FIELD.findall(rest))
        if name == "frames":
            row = screens[fields.get("screen", "unknown")]
            row["frames"] += int(fields["n"])
            row["over_budget"] += int(fields.get("missed", 0))
            row["late_start"] += int(fields.get("stalls", 0))
            row["build_max_ms"] = max(row["build_max_ms"], float(fields["buildMax"]))
            row["raster_max_ms"] = max(row["raster_max_ms"], float(fields["rasterMax"]))
            row["raster_sum_ms"] += float(fields.get("rasterSum", 0))
            row["budgets_ms"].add(float(fields["budget"]))
        elif name == "ui.blocked":
            blocks.append(fields)
        elif name == "screen.first":
            firsts.append(fields)
        elif name.endswith(".fail"):
            failures.append({"name": name, **fields})
        elif name.endswith(".end") and duration is not None:
            spans[name[:-4]].append(int(duration))
    for row in screens.values():
        n = row["frames"]
        row["over_budget_pct"] = round(100 * row["over_budget"] / n, 2) if n else None
        row["raster_mean_ms"] = round(row["raster_sum_ms"] / n, 2) if n else None
        row["budgets_ms"] = sorted(row["budgets_ms"])
    return {
        "trace_events": trace_count, "screens": dict(screens), "ui_blocks": blocks,
        "first_frames": firsts, "span_durations_ms": dict(spans), "failures": failures,
        "limits": [
            "Frame misses mean Flutter build OR raster exceeded the reported display budget",
            "These are not compositor dropped-frame counts or input-to-photon latency",
            "during:* windows overlap screen rows and must not be added to them",
            "Batch percentiles cannot produce pooled p95/p99; none are reported",
            "Trace logging and keystore startup probe are enabled in this build",
        ],
    }


def actions_from(path):
    actions = json.loads(path.read_text()) if path else []
    if not isinstance(actions, list):
        raise ValueError("Actions must be a list")
    for action in actions:
        if not isinstance(action, dict) or set(action) - {"tap", "swipe", "back", "wait"}:
            raise ValueError("Only tap, swipe, back and wait are supported")
        if sum(k in action for k in ("tap", "swipe", "back")) > 1:
            raise ValueError("Use one input per action")
        for kind, size in (("tap", 2), ("swipe", 5)):
            if kind in action and (not isinstance(action[kind], list)
                                   or len(action[kind]) != size
                                   or any(type(v) is not int or v < 0 for v in action[kind])):
                raise ValueError(f"Invalid {kind} coordinates")
        if not 0 <= float(action.get("wait", 1)) <= 60:
            raise ValueError("Action wait must be between 0 and 60 seconds")
    return actions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--seconds", type=float, default=10,
                        help="Manual capture duration, or tail after scripted inputs")
    parser.add_argument("--actions", type=Path)
    parser.add_argument("--restart", action="store_true",
                        help="Force-stop and relaunch the app, preserving accounts and disk caches")
    parser.add_argument("--disable-impeller", action="store_true",
                        help="Diagnostic launch override only; requires --restart")
    parser.add_argument("--vm-url", help="Optional localhost ADB-forwarded profile VM URL for raw timeline")
    parser.add_argument("--out", type=Path, default=ROOT / "client/out/perf")
    args = parser.parse_args()
    if args.disable_impeller and not args.restart:
        parser.error("disable-impeller requires restart")
    if args.vm_url:
        url = urlparse(args.vm_url)
        if url.scheme != "http" or url.hostname != "127.0.0.1" or args.restart:
            parser.error("vm-url must be a localhost HTTP forward and cannot accompany restart")
    if not 0 < args.seconds <= 600:
        parser.error("seconds must be between 0 and 600")
    for label in (args.label, args.scenario):
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", label):
            parser.error("Labels may only contain letters, numbers, underscores and hyphens")
    actions = actions_from(args.actions)
    pid = adb(args.serial, "shell", "pidof", PACKAGE)
    if not pid.isdigit():
        parser.error("Open Miuchio before capture; expected exactly one app process")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    folder = args.out / f"{stamp}-{args.label}-{args.scenario}"
    folder.mkdir(parents=True, exist_ok=False)
    meta = {"serial": args.serial, "pid": pid, "label": args.label,
            "scenario": args.scenario, "actions": actions, "start_utc": stamp,
            "before": read_state(args.serial)}
    for key, command in {
        "git_head": ["git", "rev-parse", "HEAD"],
        "git_status": ["git", "status", "--short"],
    }.items():
        meta[key] = subprocess.check_output(command, cwd=ROOT, text=True).strip()
    apk = ROOT / "client/build/app/outputs/flutter-apk/app-profile.apk"
    if apk.exists():
        with apk.open("rb") as stream:
            meta["local_apk_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
        meta["apk_note"] = "Hash identifies local APK; installation must be verified separately"
    foreground = str(meta["before"].get("foreground", ""))
    if PACKAGE not in foreground:
        parser.error("Miuchio must be in the foreground before capture")
    raw = folder / "trace.log"
    meta_path = folder / "metadata.json"
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    start = time.monotonic()
    with raw.open("w") as output:
        output.write(f"# miuchio.capture model={args.label} scenario={args.scenario}\n")
        output.flush()
        # A device log marker excludes replay without clearing other diagnostic logs
        process = subprocess.Popen(["adb", "-s", args.serial, "logcat",
                                    "-v", "brief", "-T", "1", "flutter:I", "MiuchioBench:I", "*:S"],
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            time.sleep(0.5)
            if process.poll() is not None:
                raise RuntimeError("logcat exited before capture began")
            adb(args.serial, "shell", "log", "-t", "MiuchioBench", stamp)
            if args.vm_url:
                meta["timeline_start_us"] = vm_call(args.vm_url, "getVMTimelineMicros")["timestamp"]
            print(f"Recording {args.label}/{args.scenario}: {folder}", flush=True)
            if args.restart:
                adb(args.serial, "shell", "am", "force-stop", PACKAGE)
                launch = ["shell", "am", "start", "-W", "-n", f"{PACKAGE}/.MainActivity"]
                if args.disable_impeller:
                    launch += ["--ez", "enable-impeller", "false"]
                meta["disable_impeller_requested"] = args.disable_impeller
                meta["launch_result"] = adb(args.serial, *launch, timeout=45)
                pid = wait_pid(args.serial)
                meta["pid"] = pid
                meta["restart"] = "Process restart with persistent account and disk cache"
            meta["input_times"] = []
            for action in actions:
                meta["input_times"].append({"elapsed_s": time.monotonic() - start, **action})
                if "tap" in action:
                    adb(args.serial, "shell", "input", "tap", *map(str, action["tap"]))
                elif "swipe" in action:
                    adb(args.serial, "shell", "input", "swipe", *map(str, action["swipe"]))
                elif action.get("back"):
                    adb(args.serial, "shell", "input", "keyevent", "KEYCODE_BACK")
                time.sleep(float(action.get("wait", 1)))
            time.sleep(args.seconds)
            if args.vm_url:
                end = vm_call(args.vm_url, "getVMTimelineMicros")["timestamp"]
                meta["timeline_end_us"] = end
                timeline = vm_call(args.vm_url, "getVMTimeline",
                                   timeOriginMicros=meta["timeline_start_us"],
                                   timeExtentMicros=end - meta["timeline_start_us"])
                (folder / "timeline.json").write_text(json.dumps(timeline) + "\n")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            meta["duration_s"] = time.monotonic() - start
            meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    lines = raw.read_text(errors="replace").splitlines()
    marker = next((i for i, line in enumerate(lines) if "MiuchioBench" in line and stamp in line), None)
    if marker is None:
        raise RuntimeError("Capture start marker missing; raw log retained, no summary generated")
    app_line = re.compile(r"/flutter\s*\(\s*" + re.escape(pid) + r"\s*\):")
    captured = [line for line in lines[marker + 1:] if app_line.search(line)]
    raw.write_text(lines[0] + "\n" + "\n".join(captured) + "\n")
    meta["after"] = read_state(args.serial)
    meta["pid_after"] = adb(args.serial, "shell", "pidof", PACKAGE)
    meta["same_process"] = meta["pid_after"] == pid
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    result = summarize(raw.read_text(errors="replace"))
    result["same_process"] = meta["same_process"]
    reported = {b for row in result["screens"].values() for b in row["budgets_ms"]}
    if args.vm_url:
        engine_budgets = set()
        for event in timeline["traceEvents"]:
            fields = event.get("args", {})
            if event.get("name") == "PlatformVsync" and "frame_target_time" in fields:
                budget = (int(fields["frame_target_time"]) - int(fields["frame_start_time"])) / 1000
                if budget > 0:
                    engine_budgets.add(round(budget, 2))
        result["engine_vsync_budgets_ms"] = sorted(engine_budgets)
        if reported and any(all(abs(b - r) > .5 for r in reported) for b in engine_budgets):
            result["budget_warning"] = (
                "Flutter probe budget disagrees with engine vsync timing during this capture; "
                "over_budget_pct is not the actual refresh-budget miss rate")
    display = str(meta["before"].get("display", ""))
    mode = re.search(r"\bmodeId (\d+)", display)
    if mode:
        rate = re.search(r"\{id=" + mode[1] + r",[^}]*?fps=([\d.]+)", display)
        if rate:
            hz = float(rate[1])
            result["android_active_refresh_hz_before"] = hz
            if hz > 0 and any(abs(b - 1000 / hz) > .5 for b in reported):
                result.setdefault("budget_warning", (
                    "Flutter probe budget disagrees with Android's active display mode; "
                    "do not interpret over_budget_pct as the actual refresh-budget miss rate"))
    (folder / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"folder": str(folder), "trace_events": result["trace_events"],
                      "screens": result["screens"], "same_process": meta["same_process"],
                      "budget_warning": result.get("budget_warning")}, indent=2))


if __name__ == "__main__":
    main()
