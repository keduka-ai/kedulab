#!/usr/bin/env bash
# Regression test: install.sh must release the controlling terminal when a
# `git clone` hits a remote that requires credentials. Without GIT_TERMINAL_PROMPT=0
# git blocks reading the username from /dev/tty forever and the installer hangs.
#
# Run under a pseudo-terminal (via `script`) so /dev/tty is live — exactly the
# condition a real `curl | bash` session has. No keystrokes are ever fed, so a
# credential prompt that reads /dev/tty would block forever.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$SCRIPT_DIR/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Mock `git`: a clone against an auth-required remote. It fails fast only when
# GIT_TERMINAL_PROMPT=0; otherwise it blocks on an interactive /dev/tty prompt.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = "clone" ]; then
    if [ "${GIT_TERMINAL_PROMPT:-}" = "0" ]; then
        echo "fatal: could not read Username: terminal prompts disabled" >&2
        exit 128
    fi
    printf "Username for 'https://example': " >&2
    read -r _ < /dev/tty
    exit 1
fi
exit 0
MOCK
chmod +x "$WORK/bin/git"

export PATH="$WORK/bin:$PATH"
unset GIT_TERMINAL_PROMPT
inner="timeout 10 bash '$INSTALL' --yes --no-prereq-check --dir '$WORK/target'"
set +e
script -qec "$inner" /dev/null </dev/null >"$WORK/out" 2>&1
set -e

prompted=0
failed_fast=0
grep -q "Username for" "$WORK/out" && prompted=1
grep -q "terminal prompts disabled" "$WORK/out" && failed_fast=1

if [ "$prompted" -eq 1 ] && [ "$failed_fast" -eq 0 ]; then
    echo "FAIL: installer hung on the clone credential prompt (terminal not released)"
    sed 's/^/  out| /' "$WORK/out"
    exit 1
fi
echo "PASS: installer released the terminal after clone"
sed 's/^/  out| /' "$WORK/out"
