#!/usr/bin/env python3
"""Run every test-*.py suite in isolated processes, including hyphenated names."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import unittest


def run_worker(path):
    # unittest discovery ignores filenames that are not Python identifiers.
    # A separate interpreter also isolates the voice runtime's module stubs.
    sys.path.insert(0, str(path.parent))
    name = path.stem.replace("-", "_")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    if suite.countTestCases() == 0:
        print(f"ERROR: no tests collected from {path}", file=sys.stderr)
        return 1
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


def run_suite(path, timeout):
    start = time.monotonic()
    process = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "--worker", str(path)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout)
        return path.name, process.returncode, output, time.monotonic() - start
    except subprocess.TimeoutExpired:
        # Release tests spawn shell/Git children; stop the whole isolated group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = process.communicate()
        return path.name, 1, output + f"\nERROR: exceeded {timeout:g}s suite timeout\n", time.monotonic() - start


def positive_int(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--jobs", type=positive_int, default=2)
    parser.add_argument("--timeout", type=positive_int, default=600, help="seconds per suite")
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        return run_worker(args.worker.resolve())
    paths = sorted(args.directory.resolve().glob("test-*.py"))
    if not paths:
        parser.error(f"no test-*.py suites found in {args.directory}")
    start = time.monotonic()
    failed = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        # Report complete suites in filename order so concurrent logs never mix.
        futures = [pool.submit(run_suite, path, args.timeout) for path in paths]
        for future in futures:
            name, code, output, seconds = future.result()
            print(f"\n--- {name}: {'PASS' if code == 0 else 'FAIL'} ({seconds:.2f}s) ---", flush=True)
            print(output, end="" if output.endswith("\n") else "\n", flush=True)
            if code:
                failed.append(name)
    print(f"\n{len(paths)} suites, {len(failed)} failed, {time.monotonic() - start:.2f}s elapsed", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
