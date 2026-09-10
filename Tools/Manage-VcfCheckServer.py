#!/usr/bin/env python3
# Copyright (c) 2026 Broadcom. All Rights Reserved.
# Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
# and/or its subsidiaries.
#
# =============================================================================
#
# SOFTWARE LICENSE AGREEMENT
#
# Copyright (c) CA, Inc. All rights reserved.
#
# You are hereby granted a non-exclusive, worldwide, royalty-free license
# under CA, Inc.'s copyrights to use, copy, modify, and distribute this
# software in source code or binary form for use in connection with CA, Inc.
# products.
#
# This copyright notice shall be included in all copies or substantial
# portions of the software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#
# =============================================================================
#
# Manage-VcfCheckServer.py
# Cross-platform background process manager for Start-VcfCheckServer.py.
#
# Usage:
#   python Manage-VcfCheckServer.py start [--port=8766] [--no-browser]
#   python Manage-VcfCheckServer.py stop
#   python Manage-VcfCheckServer.py status
#   python Manage-VcfCheckServer.py restart [--port=8766] [--no-browser]
#
# Requires the VcfCheckBaseDirectory environment variable to be set.
# The server writes its PID file to <base>/Run/vcf-check-server.pid once initialized.

import json
import os
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

_ENV_VAR_BASE_DIR  = "VcfCheckBaseDirectory"
_SERVER_SCRIPT     = Path(__file__).parent / "Start-VcfCheckServer.py"
_PID_FILENAME      = "vcf-check-server.pid"
_STOP_TIMEOUT_SECS = 10   # Seconds to wait for graceful process termination
_START_WAIT_SECS   = 8    # Seconds to wait for PID file creation on startup


def _get_base_dir() -> Path:
    """Validate and return the base directory path from environment variables."""
    val = os.environ.get(_ENV_VAR_BASE_DIR, "").strip()
    if not val:
        print(
            f"[ERROR] {_ENV_VAR_BASE_DIR} is not set.\n"
            "  Run Invoke-VcfCheckInitialize in PowerShell to create the required\n"
            "  directory structure, then try again.\n",
            file=sys.stderr,
        )
        sys.exit(1)
    p = Path(val)
    if not p.is_dir():
        print(
            f"[ERROR] {_ENV_VAR_BASE_DIR} is set to '{val}' but that path does not exist.\n"
            "  Re-run Invoke-VcfCheckInitialize to recreate the directory, then try again.\n",
            file=sys.stderr,
        )
        sys.exit(1)
    return p


def get_pid_file(base_dir: Path) -> Path:
    """Return the expected PID file path for the given base directory."""
    return base_dir / "Run" / _PID_FILENAME


def read_pid(pid_file: Path) -> "int | None":
    """Read and return the integer PID from pid_file, or None if reading fails."""
    try:
        return int(pid_file.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def is_running(pid: int) -> bool:
    """Return True if a process with the specified PID exists, without signaling or terminating it.

    Uses Win32 OpenProcess and GetExitCodeProcess API calls on Windows to avoid process termination,
    and signal 0 probe via os.kill() on POSIX platforms.
    """
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259

        handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            return False
        try:
            exit_code = wintypes.DWORD()
            if not ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
                return False
            return exit_code.value == STILL_ACTIVE
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)

    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True   # Process exists; insufficient permissions to signal
    except OSError:
        return False


def _start_background(port: int, no_browser: bool, pid_file: Path, log_file: Path) -> subprocess.Popen:
    """Launch Start-VcfCheckServer.py as a detached background process.

    Appends stdout and stderr output streams to log_file.
    """
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    log_file.parent.mkdir(parents=True, exist_ok=True)

    args = [
        sys.executable,
        str(_SERVER_SCRIPT),
        f"--port={port}",
        f"--pid-file={pid_file}",
    ]

    out = open(log_file, "a", encoding="utf-8")

    kwargs = {
        "stdout": out,
        "stderr": out,
        "stdin":  subprocess.DEVNULL,
    }

    if sys.platform == "win32":
        # DETACHED_PROCESS prevents console window creation; CREATE_NEW_PROCESS_GROUP allows process signaling
        DETACHED_PROCESS         = 0x00000008
        CREATE_NEW_PROCESS_GROUP = 0x00000200
        kwargs["creationflags"] = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    else:
        # Create new process session (setsid) to detach from the parent terminal
        kwargs["start_new_session"] = True

    proc = subprocess.Popen(args, **kwargs)
    out.close()
    return proc


def cmd_start(port: int, no_browser: bool) -> None:
    """Start the background server process if not already running."""
    base_dir = _get_base_dir()
    pid_file = get_pid_file(base_dir)

    if pid_file.exists():
        existing_pid = read_pid(pid_file)
        if existing_pid and is_running(existing_pid):
            print(f"Server is already running (PID {existing_pid}).")
            print(f"URL: http://localhost:{port}")
            return
        pid_file.unlink(missing_ok=True)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as _probe:
        _probe.settimeout(0.5)
        if _probe.connect_ex(("127.0.0.1", port)) == 0:
            print(
                f"[WARNING] Port {port} is already in use by another process.\n"
                "  A previous server instance may be running without a PID file.\n"
                "  Run 'Stop-VcfCheckServer' to stop it, or locate and kill\n"
                "  the process manually, then try again.",
                file=sys.stderr,
            )
            return

    log_filename = datetime.now().strftime("VcfCheckServer-%Y-%m-%d.log")
    log_file = base_dir / "Logs" / log_filename
    proc = _start_background(port, no_browser, pid_file, log_file)

    deadline = time.monotonic() + _START_WAIT_SECS
    while time.monotonic() < deadline:
        if pid_file.exists():
            actual_pid = read_pid(pid_file)
            if actual_pid and is_running(actual_pid):
                print(f"Server started (PID {actual_pid}) at http://localhost:{port}")
                print(f"Startup log: {log_file}")
                return
        if proc.poll() is not None:
            print(
                f"[ERROR] Server exited immediately (exit code {proc.returncode}).\n"
                f"  Check {log_file} for details.",
                file=sys.stderr,
            )
            sys.exit(1)
        time.sleep(0.1)

    print(
        f"[WARNING] Server launched but PID file did not appear within {_START_WAIT_SECS}s.\n"
        f"  The server may still be starting. Check http://localhost:{port}\n"
        f"  and {log_file} for details.",
        file=sys.stderr,
    )


def _find_orphaned_runs(base_dir: Path) -> "list[tuple[str, int, str]]":
    """Scan active run lockfiles to detect active launcher processes after server exit."""
    findings_dir = base_dir / "Findings"
    if not findings_dir.is_dir():
        return []
    orphans = []
    for lock_path in findings_dir.glob("*/.active-run.json"):
        try:
            payload = json.loads(lock_path.read_text(encoding="utf-8"))
            pid = int(payload["pid"])
            run_id = payload.get("runId", "")
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if is_running(pid):
            orphans.append((lock_path.parent.name, pid, run_id))
    return orphans


def _report_orphaned_runs(base_dir: Path) -> None:
    """Report active background runs that remain running after server shutdown."""
    for environment_slug, pid, run_id in _find_orphaned_runs(base_dir):
        print(
            f"[WARNING] Environment '{environment_slug}' still has an active run (PID {pid}, "
            f"run {run_id}) that was NOT stopped - stopping the server does not stop in-progress "
            "checks. It will keep running, and its run lock will keep blocking new runs against "
            "this environment, until it finishes on its own or you run "
            f"'Stop-Process -Id {pid}' yourself.",
            file=sys.stderr,
        )


def cmd_stop() -> None:
    """Stop the running background server process gracefully."""
    base_dir = _get_base_dir()
    pid_file = get_pid_file(base_dir)

    pid = read_pid(pid_file)
    if pid is None:
        print("Server is not running (no PID file found).")
        _report_orphaned_runs(base_dir)
        return

    if not is_running(pid):
        print(f"Server process {pid} is not running. Removing stale PID file.")
        pid_file.unlink(missing_ok=True)
        _report_orphaned_runs(base_dir)
        return

    print(f"Stopping server (PID {pid})...")
    try:
        if sys.platform == "win32":
            os.kill(pid, signal.SIGTERM)
        else:
            os.kill(pid, signal.SIGTERM)
    except OSError as exc:
        print(f"[ERROR] Could not send stop signal to PID {pid}: {exc}", file=sys.stderr)
        sys.exit(1)

    deadline = time.monotonic() + _STOP_TIMEOUT_SECS
    while time.monotonic() < deadline:
        if not is_running(pid):
            pid_file.unlink(missing_ok=True)
            if sys.platform == "win32":
                # Pause briefly on Windows to allow OS socket cleanup after process exit
                time.sleep(0.5)
            print("Server stopped.")
            _report_orphaned_runs(base_dir)
            return
        time.sleep(0.2)

    print(f"[WARNING] Server did not exit within {_STOP_TIMEOUT_SECS}s. Forcing termination...")
    try:
        if sys.platform == "win32":
            os.kill(pid, signal.SIGTERM)
        else:
            os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    time.sleep(1.0)
    pid_file.unlink(missing_ok=True)
    print("Server force-stopped.")
    _report_orphaned_runs(base_dir)


def cmd_status() -> None:
    """Report the execution status and PID of the server process."""
    base_dir = _get_base_dir()
    pid_file = get_pid_file(base_dir)

    pid = read_pid(pid_file)
    if pid is None:
        print(json.dumps({"running": False, "pid": None, "port": 8766}))
        return

    running = is_running(pid)
    if not running:
        pid_file.unlink(missing_ok=True)

    print(json.dumps({"running": running, "pid": pid, "port": 8766}))


def _usage() -> None:
    """Display command line usage instructions."""
    print(
        "Usage: python Manage-VcfCheckServer.py <command> [options]\n"
        "\n"
        "Commands:\n"
        "  start   [--port=8766] [--no-browser]   Start the server as a background process\n"
        "  stop                                    Stop the running server gracefully\n"
        "  status                                  Report whether the server is running\n"
        "  restart [--port=8766] [--no-browser]   Stop then start the server\n"
        "\n"
        "Options:\n"
        "  --port=N       Port number (default: 8766)\n"
        "  --no-browser   Do not open a browser tab on start\n"
        "\n"
        "The VcfCheckBaseDirectory environment variable must be set.\n"
        "Run Invoke-VcfCheckInitialize in PowerShell to configure it.\n"
    )


def main() -> None:
    """Parse command line arguments and execute requested manager action."""
    args = sys.argv[1:]
    if not args:
        _usage()
        sys.exit(1)

    cmd  = args[0].lower()
    port = 8766
    no_browser = False

    for arg in args[1:]:
        if arg.startswith("--port="):
            raw = arg.split("=", 1)[1]
            try:
                port = int(raw)
            except ValueError:
                print(f"[ERROR] Invalid port value: '{raw}'", file=sys.stderr)
                sys.exit(1)
            if not (1 <= port <= 65535):
                print(f"[ERROR] Port {port} out of range (1–65535).", file=sys.stderr)
                sys.exit(1)
        elif arg == "--no-browser":
            no_browser = True
        else:
            print(f"[ERROR] Unknown option: '{arg}'", file=sys.stderr)
            _usage()
            sys.exit(1)

    if cmd == "start":
        cmd_start(port, no_browser)
    elif cmd == "stop":
        cmd_stop()
    elif cmd == "status":
        cmd_status()
    elif cmd == "restart":
        cmd_stop()
        time.sleep(0.5)
        cmd_start(port, no_browser)
    else:
        print(f"[ERROR] Unknown command: '{cmd}'", file=sys.stderr)
        _usage()
        sys.exit(1)


if __name__ == "__main__":
    main()
