#!/usr/bin/env python3
"""PTY driver to test that install.sh releases the terminal after install.

Runs the installer exactly as `curl | bash` does: the script body arrives on the
child's stdin via a pipe (`cat install.sh | bash`), while a pty serves as the
controlling terminal so /dev/tty is live for prompts. We feed the prompt answers,
then HOLD the pty open (a real keyboard never sends EOF) and wait for the child to
exit with a timeout.

  - Fixed installer (prompts read from fd 3): fd 0 is the cat pipe, which EOFs when
    cat finishes, so bash exits promptly -> child reaped well under the timeout.
  - Broken installer (`exec </dev/tty` rebinds fd 0): after main() returns bash
    reads the next command from the still-open pty and blocks forever -> timeout.

Exit 0 = terminal released. Exit 1 = lingered/hung.
"""
import os, pty, sys, time, select, signal

INSTALL = sys.argv[1]
SRC = sys.argv[2]
TARGET = sys.argv[3]
TIMEOUT = 8.0

cmd = (
    f"cat {INSTALL!r} | "
    f"KEDULAB_REPO_URL={SRC!r} bash -s -- --no-prereq-check --ref main --dir {TARGET!r}"
)

pid, master = pty.fork()
if pid == 0:
    # Child: controlling terminal is the pty; /dev/tty resolves to it.
    os.execvp("bash", ["bash", "-c", cmd])
    os._exit(127)

# Parent: feed the 4 prompt answers, then hold the pty open (never send EOF).
out = bytearray()
fed = False
start = time.time()
deadline = start + TIMEOUT
exited_at = None

while True:
    if time.time() > deadline:
        break
    r, _, _ = select.select([master], [], [], 0.2)
    if master in r:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b""
        if chunk:
            out += chunk
        # else: slave side closed; loop continues until child reaped below
    if not fed and b"configure your stack" in bytes(out):
        os.write(master, b"\n\n\n\n")
        fed = True
    # Non-blocking reap.
    wpid, _ = os.waitpid(pid, os.WNOHANG)
    if wpid == pid:
        exited_at = time.time()
        break

released = exited_at is not None
elapsed = (exited_at - start) if released else (time.time() - start)

if not released:
    # Hung: kill the child so the test doesn't leak it.
    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except OSError:
        pass

text = bytes(out).decode("utf-8", "replace")
completed = "install complete" in text

sys.stdout.write(text)
sys.stdout.write("\n--- pty driver ---\n")
if not completed:
    print(f"FAIL: install did not complete (released={released}, {elapsed:.1f}s)")
    sys.exit(1)
if not released:
    print(f"FAIL: installer hung on the open tty for >{TIMEOUT:.0f}s — terminal not released after install")
    sys.exit(1)
print(f"PASS: installer released the terminal {elapsed:.1f}s after install (tty held open)")
sys.exit(0)
