#!/usr/bin/env python3
"""Measure the complete macOS audio-provider + Visualizer workload."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable


REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "cli" / "bin" / "weaver.js"
VISUALIZER = REPO / "examples" / "visualizer" / "widget.tsx"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample-seconds", type=int, default=10)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def command(arguments: list[str], *, cwd: Path = REPO,
            env: dict[str, str] | None = None) -> str:
    result = subprocess.run(arguments, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(arguments)} exited {result.returncode}\n{result.stdout}")
    return result.stdout.strip()


def wait_for(description: str, predicate: Callable[[], Any], timeout: float = 20.0) -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {description}")


def process_sample(pids: list[int]) -> dict[str, Any]:
    rows = command(["/bin/ps", "-o", "pid=,%cpu=,rss=", "-p", ",".join(map(str, pids))]).splitlines()
    values = [row.split() for row in rows if row.strip()]
    footprint = command(["/usr/bin/footprint", "-f", "bytes", *sum((["-p", str(pid)] for pid in pids), [])])
    match = re.search(r"^\s*phys_footprint:\s+(\d+) B$", footprint, re.MULTILINE)
    if not match:
        raise RuntimeError("footprint did not report aggregate phys_footprint")
    return {
        "cpu_percent_one_core": sum(float(value[1]) for value in values),
        "rss_bytes": sum(int(value[2]) * 1024 for value in values),
        "physical_footprint_bytes": int(match.group(1)),
    }


def summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        field: {
            "mean": round(statistics.fmean(sample[field] for sample in samples), 3),
            "min": min(sample[field] for sample in samples),
            "max": max(sample[field] for sample in samples),
        }
        for field in ("cpu_percent_one_core", "rss_bytes", "physical_footprint_bytes")
    } | {"samples": samples}


def main() -> int:
    if sys.platform != "darwin":
        raise RuntimeError("macOS audio cost harness requires macOS")
    args = parse_args()
    scratch = Path(tempfile.mkdtemp(prefix="weaver-audio-cost-", dir="/tmp"))
    environment = dict(os.environ)
    environment["HOME"] = str(scratch / "home")
    environment["WEAVER_AUTOMATION"] = "1"
    control = scratch / "audio-control"
    environment["WEAVER_AUDIO_TEST_CONTROL"] = str(control)
    data_root = Path(environment["HOME"]) / "Library" / "Application Support" / "Weaver"
    status_path = data_root / "status.json"
    node = shutil.which("node") or "node"
    installed: list[str] = []

    def cli(*arguments: str) -> str:
        return command([node, str(CLI), *arguments], cwd=scratch, env=environment)

    def status() -> dict[str, Any]:
        try:
            return json.loads(status_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def measure(label: str) -> dict[str, Any]:
        before = status()
        pids = [before["hostPid"], *[widget["pid"] for widget in before.get("widgets", [])]]
        samples = []
        for _ in range(args.sample_seconds):
            samples.append(process_sample(pids))
            time.sleep(1)
        after = status()
        return {
            "label": label,
            "pids": pids,
            "providers_before": before["providers"],
            "providers_after": after["providers"],
            "provider_frame_delta": after["providers"]["audioProviderFrames"] - before["providers"]["audioProviderFrames"],
            "pipe_frame_delta": after["providers"]["audioPipeFrames"] - before["providers"]["audioPipeFrames"],
            **summarize(samples),
        }

    output: dict[str, Any] = {
        "schema": "weaver.macos-production-audio-cost.v1",
        "recorded_at": command(["date", "-Iseconds"]),
        "weaver_commit": command(["git", "rev-parse", "HEAD"]),
        "macos": command(["sw_vers"]).splitlines(),
        "hardware": command(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "architecture": command(["uname", "-m"]),
        "zig": command(["zig", "version"]),
        "node": command([node, "--version"]),
        "sample_seconds": args.sample_seconds,
        "cpu_metric": "ps percent of one core summed across weaverd and participating Widget processes",
        "memory_metrics": {
            "physical_footprint": "footprint aggregate phys_footprint, de-duplicated across selected processes",
            "rss": "ps RSS summed across selected processes",
        },
        "capture_source": "automation-only 48 kHz mono injection through the production C/Zig provider seam",
        "workloads": [],
    }
    try:
        control.write_text("s", encoding="utf-8")
        cli("up")
        wait_for("host without audio subscribers", lambda: status().get("providers", {}).get("audioSubscribers") == 0)
        output["workloads"].append(measure("host, audio unsubscribed"))

        for index in (1, 2):
            directory = scratch / f"visualizer-{index}"
            cli("init", directory.name)
            source = VISUALIZER.read_text(encoding="utf-8")
            source = source.replace('name: "Visualizer"', f'name: "Visualizer {index}"')
            source = source.replace("offset: [24, 24]", f"offset: [{24 + (index - 1) * 312}, 24]")
            (directory / "widget.tsx").write_text(source, encoding="utf-8")
            cli("install", str(directory))
            installed.append(f"Visualizer {index}")

        control.write_text("a", encoding="utf-8")
        cli("audio", "authorize")
        wait_for("active two-Visualizer fan-out", lambda: status().get("providers", {}).get("audioSubscribers") == 2
                 and status()["providers"]["audioAvailability"] == "live"
                 and status()["providers"]["audioProviderFrames"] > 2)
        output["workloads"].append(measure("host + two active Visualizers"))

        control.write_text("s", encoding="utf-8")
        wait_for("silent provider parking", lambda: status().get("providers", {}).get("audioSilent") is True)
        parked = status()["providers"]["audioProviderFrames"]
        time.sleep(3)
        if status()["providers"]["audioProviderFrames"] != parked:
            raise RuntimeError("silent provider did not park before measurement")
        output["workloads"].append(measure("host + two silent parked Visualizers"))
        if output["workloads"][-1]["provider_frame_delta"] != 0:
            raise RuntimeError("silent parked provider produced frames during measurement")
    finally:
        for name in reversed(installed):
            subprocess.run([node, str(CLI), "uninstall", name], cwd=scratch, env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([node, str(CLI), "down"], cwd=scratch, env=environment,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(scratch, ignore_errors=True)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "workloads": output["workloads"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
