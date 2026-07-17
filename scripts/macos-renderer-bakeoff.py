#!/usr/bin/env python3
"""Measure complete Weaver widget processes across macOS renderer candidates.

The harness deliberately launches the production runtime without Native SDK
automation enabled.  It copies already-bundled Widgets into a run-owned root,
changes only the internal renderBackend selection and placement, samples every
process, captures Apple memory reports, then requests the AppKit SIGTERM path.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
from typing import Any


CANDIDATES = {
    "software": {"render_backend": "software", "composite": False},
    "metal-hybrid": {"render_backend": "gpu", "composite": False},
    "metal-composite": {"render_backend": "gpu", "composite": True},
}

_RUSAGE_V6_FIELDS = (
    "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups",
    "ri_pageins", "ri_wired_size", "ri_resident_size", "ri_phys_footprint",
    "ri_proc_start_abstime", "ri_proc_exit_abstime", "ri_child_user_time",
    "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
    "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
    "ri_diskio_byteswritten", "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance",
    "ri_cpu_time_qos_background", "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy",
    "ri_cpu_time_qos_user_initiated", "ri_cpu_time_qos_user_interactive",
    "ri_billed_system_time", "ri_serviced_system_time", "ri_logical_writes",
    "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
    "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint",
    "ri_runnable_time", "ri_flags", "ri_user_ptime", "ri_system_ptime",
    "ri_pinstructions", "ri_pcycles", "ri_energy_nj", "ri_penergy_nj",
    "ri_secure_time_in_system", "ri_secure_ptime_in_system", "ri_neural_footprint",
    "ri_lifetime_max_neural_footprint", "ri_interval_max_neural_footprint",
)


class RUsageInfoV6(ctypes.Structure):
    _fields_ = ([
        ("ri_uuid", ctypes.c_uint8 * 16),
    ] + [(name, ctypes.c_uint64) for name in _RUSAGE_V6_FIELDS] + [
        ("ri_reserved", ctypes.c_uint64 * 9),
    ])


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib") if sys.platform == "darwin" else None
if LIBPROC is not None:
    LIBPROC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int,
                                       ctypes.POINTER(RUsageInfoV6)]
    LIBPROC.proc_pid_rusage.restype = ctypes.c_int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--candidate", choices=CANDIDATES, required=True)
    parser.add_argument("--bundles", type=Path, nargs="+", required=True)
    parser.add_argument("--count", type=int, choices=(1, 3, 10), required=True)
    parser.add_argument("--warmup-seconds", type=float, default=5.0)
    parser.add_argument("--sample-seconds", type=int, default=10)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--frame-trace", action="store_true")
    parser.add_argument("--stage-trace", action="store_true")
    return parser.parse_args()


def run_text(args: list[str]) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=False)
    return result.stdout


def copy_instance(source: Path, destination: Path, index: int,
                  candidate: str) -> dict[str, Any]:
    if not (source / "bundle.js").is_file() or not (source / "widget.json").is_file():
        raise RuntimeError(f"bundle is incomplete: {source}")
    shutil.copytree(source, destination)
    manifest_path = destination / "widget.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["name"] = f"Bakeoff {candidate} {index + 1}"
    manifest["renderBackend"] = CANDIDATES[candidate]["render_backend"]
    # Five small static Widgets fit across the integrated display. Larger
    # mixed/synthetic surfaces may overlap, but stay on-screen and retain an
    # honest visible AppKit surface instead of becoming off-screen/occluded.
    manifest["anchor"] = {
        "monitor": "primary",
        "corner": "top-left",
        "offset": [24 + (index % 5) * 260, 24 + (index // 5) * 350],
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def process_sample(pid: int) -> dict[str, Any]:
    output = run_text(["/bin/ps", "-o", "pid=,%cpu=,rss=,state=", "-p", str(pid)]).strip()
    fields = output.split()
    if len(fields) < 4:
        raise RuntimeError(f"process {pid} exited during sampling: {output!r}")
    thread_lines = run_text(["/bin/ps", "-M", "-p", str(pid)]).splitlines()
    return {
        "pid": pid,
        "cpu_percent_one_core": float(fields[1]),
        "rss_bytes": int(fields[2]) * 1024,
        "threads": max(0, len(thread_lines) - 1),
        "state": fields[3],
    }


def process_rusage(pid: int) -> dict[str, int]:
    info = RUsageInfoV6()
    if LIBPROC is None or LIBPROC.proc_pid_rusage(pid, 6, ctypes.byref(info)) != 0:
        raise RuntimeError(f"proc_pid_rusage failed for process {pid}")
    return {name: int(getattr(info, name)) for name in _RUSAGE_V6_FIELDS}


def rusage_delta(start: list[dict[str, int]], end: list[dict[str, int]]) -> dict[str, int]:
    wanted = (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups",
        "ri_instructions", "ri_cycles", "ri_billed_energy", "ri_serviced_energy",
        "ri_runnable_time", "ri_energy_nj", "ri_penergy_nj",
    )
    return {
        name.removeprefix("ri_"): sum(after[name] - before[name]
                                      for before, after in zip(start, end))
        for name in wanted
    }


def summarize_samples(samples: list[list[dict[str, Any]]]) -> dict[str, Any]:
    total_cpu = [sum(item["cpu_percent_one_core"] for item in row) for row in samples]
    total_rss = [sum(item["rss_bytes"] for item in row) for row in samples]
    total_threads = [sum(item["threads"] for item in row) for row in samples]
    return {
        "total_cpu_percent_one_core": {
            "mean": statistics.fmean(total_cpu),
            "min": min(total_cpu),
            "max": max(total_cpu),
        },
        "total_rss_bytes": {
            "mean": round(statistics.fmean(total_rss)),
            "min": min(total_rss),
            "max": max(total_rss),
        },
        "total_threads": {
            "mean": statistics.fmean(total_threads),
            "min": min(total_threads),
            "max": max(total_threads),
        },
    }


def parse_footprint(text: str) -> dict[str, int]:
    parsed: dict[str, int] = {}
    for key in ("phys_footprint", "phys_footprint_peak"):
        match = re.search(rf"^\s*{key}:\s*(\d+) B$", text, re.MULTILINE)
        if match:
            parsed[f"{key}_bytes"] = int(match.group(1))
    return parsed


def parse_vmmap(text: str) -> dict[str, int]:
    parsed: dict[str, int] = {}
    total = re.search(
        r"^TOTAL\s+\S+\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\d+\s*$",
        text, re.MULTILINE,
    )
    if total:
        parsed["resident_display"] = total.group(1)
        parsed["dirty_display"] = total.group(2)
        parsed["swapped_display"] = total.group(3)
        parsed["volatile_display"] = total.group(4)
        parsed["nonvolatile_display"] = total.group(5)
    for label, key in (("IOAccelerator (graphics)", "ioaccelerator_graphics"),
                       ("IOSurface", "iosurface"),
                       ("CG image", "cg_image")):
        match = re.search(rf"^{re.escape(label)}\s+(\S+)\s+(\S+)\s+(\S+)", text, re.MULTILINE)
        if match:
            parsed[f"{key}_virtual_display"] = match.group(1)
            parsed[f"{key}_resident_display"] = match.group(2)
            parsed[f"{key}_dirty_display"] = match.group(3)
    return parsed


def main() -> int:
    args = parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("this harness measures the macOS process implementation")
    runtime = args.runtime.resolve()
    if not runtime.is_file():
        raise RuntimeError(f"runtime does not exist: {runtime}")
    bundles = [path.resolve() for path in args.bundles]
    output = args.output.resolve()
    run_root = output.parent / f"{output.stem}-run"
    if run_root.exists():
        shutil.rmtree(run_root)
    run_root.mkdir(parents=True)
    output.parent.mkdir(parents=True, exist_ok=True)

    candidate = CANDIDATES[args.candidate]
    processes: list[subprocess.Popen[bytes]] = []
    streams: list[Any] = []
    manifests = []
    launch_monotonic = time.monotonic_ns()
    try:
        for index in range(args.count):
            instance = run_root / f"widget-{index + 1:02d}"
            manifests.append(copy_instance(bundles[index % len(bundles)], instance,
                                           index, args.candidate))
            home = run_root / f"home-{index + 1:02d}"
            home.mkdir()
            stream = (run_root / f"process-{index + 1:02d}.log").open("wb")
            streams.append(stream)
            env = os.environ.copy()
            env["HOME"] = str(home)
            if candidate["composite"]:
                env["NATIVE_SDK_GPU_COMPOSITE"] = "1"
            else:
                env.pop("NATIVE_SDK_GPU_COMPOSITE", None)
            if args.frame_trace:
                env["NATIVE_SDK_GPU_FRAME_TRACE"] = "1"
            else:
                env.pop("NATIVE_SDK_GPU_FRAME_TRACE", None)
            if args.stage_trace:
                env["NATIVE_SDK_RENDERER_BAKEOFF_TRACE"] = "1"
            else:
                env.pop("NATIVE_SDK_RENDERER_BAKEOFF_TRACE", None)
            processes.append(subprocess.Popen([str(runtime), str(instance)],
                                              cwd=run_root, env=env,
                                              stdout=stream, stderr=subprocess.STDOUT))

        time.sleep(args.warmup_seconds)
        rusage_start = [process_rusage(process.pid) for process in processes]
        sample_window_begin_ns = time.monotonic_ns()
        samples: list[list[dict[str, Any]]] = []
        for sample_index in range(args.sample_seconds):
            sample_begin = time.monotonic()
            samples.append([process_sample(process.pid) for process in processes])
            remaining = sample_begin + 1.0 - time.monotonic()
            if sample_index + 1 < args.sample_seconds and remaining > 0:
                time.sleep(remaining)
        rusage_end = [process_rusage(process.pid) for process in processes]
        sample_window_ns = time.monotonic_ns() - sample_window_begin_ns

        process_reports = []
        for index, process in enumerate(processes):
            footprint = run_text(["/usr/bin/footprint", "--noCategories", "--swapped",
                                  "--format", "bytes", "-p", str(process.pid)])
            vmmap = run_text(["/usr/bin/vmmap", "-summary", str(process.pid)])
            (run_root / f"footprint-{index + 1:02d}.txt").write_text(footprint, encoding="utf-8")
            (run_root / f"vmmap-{index + 1:02d}.txt").write_text(vmmap, encoding="utf-8")
            fd_lines = run_text(["/usr/sbin/lsof", "-p", str(process.pid)]).splitlines()
            process_reports.append({
                "pid": process.pid,
                "file_descriptors": max(0, len(fd_lines) - 1),
                **parse_footprint(footprint),
                **parse_vmmap(vmmap),
            })

        stop_begin = time.monotonic_ns()
        for process in processes:
            process.send_signal(signal.SIGTERM)
        exit_codes = []
        for process in processes:
            try:
                exit_codes.append(process.wait(timeout=10))
            except subprocess.TimeoutExpired:
                process.kill()
                exit_codes.append(process.wait())
        teardown_ns = time.monotonic_ns() - stop_begin

        result = {
            "schema": 1,
            "candidate": args.candidate,
            "candidate_contract": candidate,
            "count": args.count,
            "bundle_cycle": [str(path) for path in bundles],
            "runtime": str(runtime),
            "warmup_seconds": args.warmup_seconds,
            "sample_seconds": args.sample_seconds,
            "launch_to_sample_end_ns": time.monotonic_ns() - launch_monotonic,
            "manifests": manifests,
            "samples": samples,
            "summary": summarize_samples(samples),
            "rusage_delta": rusage_delta(rusage_start, rusage_end),
            "rusage_sample_window_ns": sample_window_ns,
            "process_reports": process_reports,
            "total_phys_footprint_bytes": sum(report.get("phys_footprint_bytes", 0)
                                                for report in process_reports),
            "total_phys_footprint_peak_bytes": sum(report.get("phys_footprint_peak_bytes", 0)
                                                     for report in process_reports),
            "total_file_descriptors": sum(report["file_descriptors"]
                                            for report in process_reports),
            "teardown_ns": teardown_ns,
            "exit_codes": exit_codes,
            "raw_report_directory": str(run_root),
        }
        output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({
            "output": str(output),
            "candidate": args.candidate,
            "count": args.count,
            "summary": result["summary"],
            "total_phys_footprint_bytes": result["total_phys_footprint_bytes"],
            "total_file_descriptors": result["total_file_descriptors"],
            "teardown_ns": teardown_ns,
            "exit_codes": exit_codes,
        }, indent=2))
        return 0 if all(code == 0 for code in exit_codes) else 1
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
        for stream in streams:
            stream.close()


if __name__ == "__main__":
    raise SystemExit(main())
