#!/usr/bin/env bash
# Static checks on the Dockerfile. No daemon needed — these are grep-level
# invariants that are cheap to assert and expensive to rediscover.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DF="$ROOT/Dockerfile"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- Case 1: git is installed -------------------------------------------
# Notebooks routinely run `!git clone` and `!pip install git+https://...`, and
# nbdime (pinned in requirements.txt) is a git notebook-diff tool that is inert
# without a git binary.
grep -vE '^\s*#' "$DF" | grep -qE '(^|\s)git(\s|\\|$)' \
    || fail "git is not installed at apt level — '!git clone', 'pip install git+...' and nbdime all fail"

# ---- Case 2: the base image is parameterised so it can be digest-pinned ---
grep -qE '^ARG BASE_IMAGE=' "$DF" \
    || fail "Dockerfile has no BASE_IMAGE ARG — the base image cannot be pinned by digest without editing the file"
grep -qE '^FROM \$\{BASE_IMAGE\}' "$DF" \
    || fail "the base stage does not build FROM \${BASE_IMAGE}"

# ---- Case 2b: build-arg references are in scope where they are used ------
# ARG scoping is the one Dockerfile rule that grep-level presence checks miss
# entirely, and neither hadolint nor `docker compose config` catches it:
#
#   * An ARG declared AFTER the first FROM belongs to that build stage, not to
#     the global scope. A later `FROM ${VAR}` then resolves against an empty
#     global scope and BuildKit hard-fails with
#     "base name (${VAR}) should not be blank".
#   * An ARG goes out of scope at the end of the stage that declared it. A
#     child stage (`FROM base AS jupyter`) does NOT inherit it — only ENV
#     crosses the boundary. `COPY --chown=${USER_UID}:${USER_GID}` in a stage
#     that never re-declared USER_UID expands to `--chown=:` and the COPY
#     fails with "COPY requires at least two arguments".
#
# The fix for the second case is a bare `ARG USER_UID` (no default) in the
# consuming stage, which pulls the value from the global declaration — so the
# defaults stay defined exactly once.
#
# Only build-time expansion is checked. CMD / ENTRYPOINT / HEALTHCHECK bodies
# are expanded by the shell inside the running container, so a reference like
# ${JUPYTER_PORT:-8888} there is correct and must not be flagged.
#
# Sharp edge: a RUN body IS checked, because a build arg used there is only
# populated if the stage declared it. A shell-local variable introduced inside
# the RUN itself (`for f in *; do … $f`) has no ARG/ENV backing and will trip
# this check — add such names to the `inherited` allowlist in the END block.
scope_report="$(awk '
    # --- helpers ----------------------------------------------------------
    function note_refs(text, lineno,    rest, name) {
        rest = text
        while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
            name = substr(rest, RSTART, RLENGTH)
            sub(/^\$\{?/, "", name)
            refs[++nref] = name SUBSEP stage SUBSEP lineno
            rest = substr(rest, RSTART + RLENGTH)
        }
    }

    # --- skip comments, remember line continuations ------------------------
    /^[[:space:]]*#/ { next }
    {
        if (!cont) {
            instr = toupper($1)
            first = 1
        } else {
            first = 0
        }
        cont = ($0 ~ /\\[[:space:]]*$/)
    }

    # --- stage boundaries --------------------------------------------------
    instr == "FROM" && first {
        nstage++
        name = ""
        for (i = 2; i <= NF; i++) if (toupper($i) == "AS") name = $(i + 1)
        if (name == "") name = "#" nstage
        parent[name] = $2
        stage = name
        # A FROM base name resolves against the GLOBAL arg scope only.
        rest = $2
        while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
            v = substr(rest, RSTART, RLENGTH)
            sub(/^\$\{?/, "", v)
            if (!(v in globalarg))
                print "FROM (line " NR ") uses ${" v "} but ARG " v \
                      " is not declared before the first FROM"
            rest = substr(rest, RSTART + RLENGTH)
        }
        next
    }

    # --- declarations ------------------------------------------------------
    instr == "ARG" && first {
        for (i = 2; i <= NF; i++) {
            n = $i; sub(/=.*$/, "", n)
            if (n ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                if (nstage == 0) globalarg[n] = 1
                else declared[stage SUBSEP n] = 1
            }
        }
        next
    }
    instr == "ENV" && first {
        n = $2; sub(/=.*$/, "", n)
        if (n ~ /^[A-Za-z_][A-Za-z0-9_]*$/) env[stage SUBSEP n] = 1
        # ENV values are themselves build-time expanded.
        note_refs(substr($0, index($0, $2) + length($2)), NR)
        next
    }

    # --- runtime-only instructions: not build-time expanded ----------------
    instr == "CMD" || instr == "ENTRYPOINT" || instr == "HEALTHCHECK" { next }

    # --- everything else is build-time expanded ---------------------------
    nstage > 0 { note_refs($0, NR) }

    END {
        # Vars supplied by the base image or the builder, not by this file.
        inherited["PATH"] = 1; inherited["HOME"] = 1; inherited["LANG"] = 1
        inherited["TARGETPLATFORM"] = 1; inherited["TARGETARCH"] = 1
        inherited["BUILDPLATFORM"] = 1; inherited["TARGETOS"] = 1

        for (i = 1; i <= nref; i++) {
            split(refs[i], p, SUBSEP)
            name = p[1]; st = p[2]; ln = p[3]
            if (name in inherited) continue
            if (declared[st SUBSEP name]) continue
            # ENV crosses stage boundaries; ARG does not.
            ok = 0; cur = st
            while (cur != "" && !ok) {
                if (env[cur SUBSEP name]) ok = 1
                cur = parent[cur]
            }
            if (!ok)
                print "line " ln " (stage " st ") uses ${" name "} but it is " \
                      "neither an ARG declared in that stage nor an inherited ENV"
        }
    }
' "$DF")"

[ -z "$scope_report" ] || fail "Dockerfile references build args that are out of scope:
$scope_report"

# ---- Case 3: uv stays pinned and copied, never curl|sh -------------------
grep -qE '^FROM ghcr\.io/astral-sh/uv:\$\{UV_VERSION\}' "$DF" \
    || fail "uv is no longer copied from the pinned ghcr.io/astral-sh/uv image"
if grep -qE 'curl.*astral.*\|\s*(sh|bash)' "$DF"; then
    fail "Dockerfile fetches and executes the uv install script — use the pinned COPY --from=uv-bin instead"
fi

# ---- Case 4: no raw `pip install <pkg>` at build time --------------------
# Project rule: build-time installs go exclusively through `uv pip install -r`.
# pip exists in the image only for the interactive in-notebook path.
if grep -nE '^\s*RUN.*(^|[^-])\bpip install\b' "$DF" | grep -vq 'uv pip install'; then
    if grep -nE '(^|\s)pip install\s+[a-zA-Z]' "$DF" | grep -v 'uv pip install' | grep -vq 'pip-audit'; then
        fail "Dockerfile contains a raw 'pip install <pkg>':
$(grep -nE '(^|\s)pip install\s+[a-zA-Z]' "$DF" | grep -v 'uv pip install')"
    fi
fi

# ---- Case 4b: the lockfile path is buildable without editing the file ----
# `uv pip install --require-hashes` only works if EVERY input file carries
# hashes, and the jupyter target installs jupyter-base + the project file in a
# single resolver pass. So pointing REQUIREMENTS_FILE at a .lock is not enough
# on its own — the jupyter-base file has to be swappable too.
grep -qE '^ARG JUPYTER_BASE_FILE=' "$DF" \
    || fail "no JUPYTER_BASE_FILE ARG — a hash-checked build can't replace jupyter-base.txt with jupyter-base.lock"
grep -qE '^ARG REQUIRE_HASHES=' "$DF" \
    || fail "no REQUIRE_HASHES ARG — --require-hashes still needs a manual Dockerfile edit"
grep -q 'require-hashes' "$DF" \
    || fail "REQUIRE_HASHES is declared but never passed to uv pip install"

# ---- Case 5: the container does not run as root -------------------------
grep -qE '^USER jovyan' "$DF" \
    || fail "Dockerfile never switches to the non-root jovyan user"
[ "$(grep -cE '^USER jovyan' "$DF")" -ge 1 ] || fail "no USER jovyan directive"
# The final directive before CMD must drop back to jovyan.
last_user="$(grep -E '^USER ' "$DF" | tail -1)"
[ "$last_user" = "USER jovyan" ] \
    || fail "the last USER directive is '$last_user'; the image must end up running as jovyan"

echo "PASS: Dockerfile installs git, parameterises BASE_IMAGE, pins uv, avoids raw pip, and ends as jovyan"
