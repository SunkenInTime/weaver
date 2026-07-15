#!/usr/bin/env python3
"""Measure the complete host + Widget cost of macOS system-provider fan-out."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable


REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "cli" / "bin" / "weaver.js"
SYSTEM_SOURCE = REPO / "examples" / "system" / "widget.tsx"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample-seconds", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def command(args: list[str], *, cwd: Path = REPO, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} exited {result.returncode}\n{result.stdout}")
    return result.stdout.strip()


def wait_for(description: str, predicate: Callable[[], Any], timeout: float = 15.0) -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {description}")


def process_sample(pid: int) -> dict[str, Any]:
    fields = command(["/bin/ps", "-o", "pid=,%cpu=,rss=,state=", "-p", str(pid)]).split()
    if len(fields) < 4:
        raise RuntimeError(f"process {pid} exited while sampling")
    threads = max(0, len(command(["/bin/ps", "-M", "-p", str(pid)]).splitlines()) - 1)
    return {
        "pid": pid,
        "cpu_percent_one_core": float(fields[1]),
        "rss_bytes": int(fields[2]) * 1024,
        "threads": threads,
        "state": fields[3],
    }


def summarize(rows: list[list[dict[str, Any]]]) -> dict[str, Any]:
    cpu = [sum(process["cpu_percent_one_core"] for process in row) for row in rows]
    rss = [sum(process["rss_bytes"] for process in row) for row in rows]
    threads = [sum(process["threads"] for process in row) for row in rows]
    return {
        "total_cpu_percent_one_core": {"mean": statistics.fmean(cpu), "min": min(cpu), "max": max(cpu)},
        "total_rss_bytes": {"mean": round(statistics.fmean(rss)), "min": min(rss), "max": max(rss)},
        "total_threads": {"mean": statistics.fmean(threads), "min": min(threads), "max": max(threads)},
        "samples": rows,
    }


def main() -> int:
    if sys.platform != "darwin":
        raise RuntimeError("macOS provider cost harness requires macOS")
    args = parse_args()
    scratch = Path(tempfile.mkdtemp(prefix="weaver-provider-cost-", dir="/tmp"))
    environment = dict(os.environ)
    environment["HOME"] = str(scratch / "home")
    data_root = Path(environment["HOME"]) / "Library" / "Application Support" / "Weaver"
    status_path = data_root / "status.json"

    def cli(*arguments: str) -> str:
        return command([process_executable(), str(CLI), *arguments], cwd=scratch, env=environment)

    def status() -> dict[str, Any]:
        try:
            return json.loads(status_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def create_system(index: int) -> Path:
        directory = scratch / f"system-{index}"
        cli("init", directory.name)
        source = SYSTEM_SOURCE.read_text(encoding="utf-8")
        source = source.replace('name: "System Monitor"', f'name: "System Monitor {index}"')
        source = source.replace("offset: [24, 24]", f"offset: [{24 + (index - 1) * 320}, 24]")
        (directory / "widget.tsx").write_text(source, encoding="utf-8")
        return directory

    def measure(label: str) -> dict[str, Any]:
        document = status()
        pids = [document["hostPid"], *[widget["pid"] for widget in document.get("widgets", []) if widget["pid"] > 0]]
        provider_start = dict(document["providers"])
        rows: list[list[dict[str, Any]]] = []
        for _ in range(args.sample_seconds):
            rows.append([process_sample(pid) for pid in pids])
            time.sleep(1)
        provider_end = dict(status()["providers"])
        return {
            "label": label,
            "pids": pids,
            "provider_start": provider_start,
            "provider_end": provider_end,
            "provider_sample_delta": provider_end["systemSampleCount"] - provider_start["systemSampleCount"],
            "provider_frame_delta": provider_end["systemFrames"] - provider_start["systemFrames"],
            **summarize(rows),
        }

    output: dict[str, Any] = {
        "recorded_at": command(["date", "-Iseconds"]),
        "weaver_commit": command(["git", "rev-parse", "HEAD"]),
        "macos": command(["sw_vers"]).splitlines(),
        "hardware": command(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "architecture": command(["uname", "-m"]),
        "zig": command(["zig", "version"]),
        "node": command([process_executable(), "--version"]),
        "sample_seconds": args.sample_seconds,
        "memory_metric": "ps RSS bytes summed across weaverd and all participating Widget processes",
        "cpu_metric": "ps percent of one core summed across weaverd and all participating Widget processes",
        "workloads": [],
    }
    names: list[str] = []
    try:
        cli("up")
        wait_for("empty host status", lambda: status().get("providers", {}).get("systemSubscribers") == 0)
        time.sleep(2)
        output["workloads"].append(measure("host, zero subscribers"))
        if output["workloads"][-1]["provider_sample_delta"] != 0:
            raise RuntimeError("host sampled CPU/memory with zero subscribers")

        sources = [create_system(index) for index in range(1, 4)]
        cli("install", str(sources[0]))
        names.append("System Monitor 1")
        wait_for("one system subscriber", lambda: status().get("providers", {}).get("systemSubscribers") == 1 and status()["providers"]["systemFrames"] >= 2)
        time.sleep(2)
        output["workloads"].append(measure("host + one System Widget"))

        for index in (1, 2):
            cli("install", str(sources[index]))
            names.append(f"System Monitor {index + 1}")
        wait_for("three system subscribers", lambda: status().get("providers", {}).get("systemSubscribers") == 3)
        time.sleep(2)
        output["workloads"].append(measure("host + three System Widgets"))
    finally:
        for name in reversed(names):
            subprocess.run([process_executable(), str(CLI), "uninstall", name], cwd=scratch,
                           env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([process_executable(), str(CLI), "down"], cwd=scratch, env=environment,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(scratch, ignore_errors=True)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "workloads": output["workloads"]}, indent=2))
    return 0


def process_executable() -> str:
    return shutil.which("node") or "node"


if __name__ == "__main__":
    raise SystemExit(main())
