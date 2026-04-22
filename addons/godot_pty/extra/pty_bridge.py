#!/usr/bin/env python3
"""
Optimized PTY bridge for GodotPTY using TCP.
"""

import fcntl
import os
import pty
import select
import signal
import socket
import struct
import sys
import termios


def _set_winsize(fd: int, rows: int, cols: int) -> None:
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def main() -> None:
    port  = int(sys.argv[1]) if len(sys.argv) > 1 else 55399
    cols  = int(sys.argv[2]) if len(sys.argv) > 2 else 80
    rows  = int(sys.argv[3]) if len(sys.argv) > 3 else 24
    shell = sys.argv[4]      if len(sys.argv) > 4 else os.environ.get("SHELL", "/bin/bash")

    # ── 1. Fork the shell inside a PTY ───────────────────────────────────────
    pid, master_fd = pty.fork()

    if pid == 0:
        # Child process: become the shell
        os.environ["TERM"]      = "xterm-256color"
        os.environ["COLORTERM"] = "truecolor"
        for var in ("LANG", "LC_ALL", "LC_CTYPE"):
            if not os.environ.get(var):
                os.environ[var] = "en_US.UTF-8"
        os.execvp(shell, [shell])
        sys.exit(127)

    # Parent: configure initial terminal size
    _set_winsize(master_fd, rows, cols)

    # ── 2. Accept one TCP connection from Godot ───────────────────────────────
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    srv.settimeout(30)

    try:
        conn, _ = srv.accept()
    except socket.timeout:
        os.kill(pid, signal.SIGTERM)
        sys.exit(1)
    finally:
        srv.close()

    conn.setblocking(False)

    # ── 3. Proxy loop ─────────────────────────────────────────────────────────
    resize_buf = bytearray()
    RESIZE_MAGIC = b"\x00R"

    try:
        while True:
            # Use None for timeout to block until data is actually available.
            # This eliminates the polling lag.
            try:
                r, _, _ = select.select([master_fd, conn], [], [])
            except (ValueError, OSError, select.error):
                break

            # PTY → Godot
            if master_fd in r:
                try:
                    data = os.read(master_fd, 8192)
                    if not data:
                        break
                    conn.sendall(data)
                except OSError:
                    break

            # Godot → PTY
            if conn in r:
                try:
                    raw = conn.recv(8192)
                    if not raw:
                        break
                    resize_buf += raw

                    while resize_buf:
                        idx = resize_buf.find(RESIZE_MAGIC)
                        if idx == -1:
                            os.write(master_fd, bytes(resize_buf))
                            resize_buf.clear()
                            break
                        if idx > 0:
                            os.write(master_fd, bytes(resize_buf[:idx]))
                            del resize_buf[:idx]
                        if len(resize_buf) < 6:
                            break
                        _, _, ch, cl, rh, rl = resize_buf[:6]
                        del resize_buf[:6]
                        new_cols = (ch << 8) | cl
                        new_rows = (rh << 8) | rl
                        _set_winsize(master_fd, new_rows, new_cols)
                        os.kill(pid, signal.SIGWINCH)
                except (BlockingIOError, OSError):
                    pass

            # Detect shell exit
            try:
                wpid, _ = os.waitpid(pid, os.WNOHANG)
                if wpid == pid:
                    break
            except ChildProcessError:
                break

    finally:
        conn.close()
        try:
            os.close(master_fd)
        except OSError:
            pass
        try:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass


if __name__ == "__main__":
    main()
