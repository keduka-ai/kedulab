# Changelog

All notable changes to **kedulab** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project loosely follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — build metadata after `+` is a date stamp.

## [Unreleased]

_No unreleased changes._

## [v0.1.3+20260529] — 2026-05-29

Bugfix release for the `install.sh` bootstrap. No image, dependency, or runtime behavior changes.

### Fixed

- **Streamed installer hung after the next-steps command was echoed.** `open_tty` ran `exec </dev/tty`, rebinding the script's own `fd 0`; under `curl | bash` (where bash reads the script body from `fd 0`) this made bash read the next command from the keyboard after `main()` returned, so the installer never released the terminal. Prompts now read from a dedicated `fd 3`, `fd 0` is left untouched, the TTY fd is closed via `release_tty` once configuration finishes, and the script ends with an explicit `exit 0`.
- **`git clone` blocked forever on a credential prompt** for private/typo'd/expired remotes. The clone now runs with `GIT_TERMINAL_PROMPT=0` and stdin detached so it fails fast; configured credential helpers still work.
- **Prerequisite probes could grab the terminal.** `docker version`, `docker compose version`, and the GPU smoke test now run with stdin detached (`</dev/null`).

### Added

- **Installer regression tests.** `tests/install_terminal_test.sh` (clone credential fail-fast) and `tests/install_release_test.sh` + `tests/pty_release.py` (terminal release after a full streamed interactive install, driven through a real pty).

## [v0.0.1+20260528] — 2026-05-28

First working implementation. This is the initial substantive cut of kedulab — a Dockerized, `uv`-managed JupyterLab launcher for GPU ML/NLP work, designed to spin up multiple independent stacks side-by-side with one image per project.

### Added

- **Image build pipeline.** Multi-stage `Dockerfile` (`uv-bin`, `base`, `shell`, `jupyter` targets) on `nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04`. Python (default 3.12) installed into `/opt/venv` via `uv`; the `uv` binary itself copied from the pinned `ghcr.io/astral-sh/uv:${UV_VERSION}` image at build time (no `install.sh` fetch).
- **Compose service.** Single parameterized `jupyter` service in `docker-compose.yml`. Build args: `REQUIREMENTS_FILE`, `PYTHON_VERSION`, `USER_UID`, `USER_GID`, `UV_VERSION`, `PIP_AUDIT_STRICT`. Runtime env: `BIND_ADDR`, `HOST_PORT`, `MOUNT_PATH`, `MEMORY_LIMIT`, `CPU_LIMIT`, `SHM_SIZE`, `JUPYTER_PASSWORD_HASH`. Host↔container port mapping is 1:1 so the URL JupyterLab prints matches the URL the user opens.
- **Two-tier requirements split.** `jupyter-base.txt` for JupyterLab plumbing (always installed); `requirements.txt` for default ML/NLP deps; `requirements-distributed.txt` for Ray / Kubernetes / KFP; `requirements-kais.txt` for KAIS-internal extras. Per-project `requirements-<project>.txt` files swap in via the `REQUIREMENTS_FILE` build arg.
- **`pyproject.toml` scaffold.** Mirrors the requirements files via `[project.optional-dependencies]` groups (`jupyter`, `distributed`, `kais`) for host-side `uv sync --extra <group>` workflows. Not yet wired into the Docker build path.
- **`scripts/entrypoint.sh`.** JupyterLab launcher that swaps from auto-token auth to hashed-password auth when `JUPYTER_PASSWORD_HASH` is set — no rebuild required.
- **`scripts/lock.sh`.** Generates `uv pip compile --generate-hashes` lockfiles from any `requirements*.txt`, for reproducible builds against `REQUIREMENTS_FILE=<file>.lock`.
- **`install.sh` — one-liner bootstrap installer.** `curl -fsSL https://raw.githubusercontent.com/keduka/kedulab/main/install.sh | bash` flow: verifies Docker / Compose v2 / NVIDIA Container Toolkit (GPU smoke test against `nvidia/cuda:12.4.1-base-ubuntu22.04`), clones the repo, walks the user through `COMPOSE_PROJECT_NAME` / `REQUIREMENTS_FILE` / `MOUNT_PATH` / `HOST_PORT` with sensible defaults, writes `.env`, creates the mount-path directory, prints the configured `docker compose up` command. Flags: `--ref`, `--dir`, `--yes`, `--no-prereq-check`, `--help`. Env-var overrides: `KEDULAB_PROJECT`, `KEDULAB_REQUIREMENTS_FILE`, `KEDULAB_MOUNT_PATH`, `KEDULAB_HOST_PORT`, `KEDULAB_REPO_URL` (for forks). Opens `/dev/tty` so prompts work under `curl | bash`; falls back to default-acceptance when no TTY is available.
- **Branded README.** Centered logo, project tagline, badge row (Keduka, MIT, CUDA 12.4, Python 3.12, JupyterLab), "About Keduka" section tying the project to KAIS/KCS, a "First run" walkthrough with three onboarding screenshots, full Configuration table, multi-stack workflow, security posture, troubleshooting, and footer.
- **Onboarding screenshots.** `assets/screenshots/01-launcher-default-and-ml-kernels.png` (Launcher with both stock `Python 3 (ipykernel)` and project `ml` kernel), `02-notebook-context-menu-rename.png` (right-click Rename), `03-rename-file-dialog.png` (Rename dialog).
- **Keduka logo set.** `assets/logos/logo1_c_t.png` and 64×64 variants.

### Security

- **Non-root runtime.** Container runs as `jovyan` (UID/GID `1000:1000`, overridable via `USER_UID`/`USER_GID` build args). Both `/opt/venv` and `/home/workspace` are chowned to that user. `--allow-root` is *not* on the Jupyter `CMD`.
- **Locked-down compose service.** `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `read_only: true` rootfs with `tmpfs` for `/tmp`, `/home/jovyan/.jupyter`, `/home/jovyan/.local`, `/home/jovyan/.cache`, `/home/jovyan/.ipython`. Only the bind-mounted `/home/workspace` is persistently writable.
- **Loopback bind by default.** `BIND_ADDR=127.0.0.1`. Public binds require `JUPYTER_PASSWORD_HASH` to be set (generated via `python -c "from jupyter_server.auth import passwd; print(passwd())"`) and are documented as "only behind a real auth proxy."
- **Resource caps.** `memory: 16G`, `cpus: 8`, `shm_size: 2gb` defaults; all overridable.
- **Pinned tooling.** `uv` binary pinned to `ghcr.io/astral-sh/uv:${UV_VERSION}` (default `0.5.11`). No unverified `install.sh` fetch at image build time.
- **`pip-audit` build gate.** Opt-in via `PIP_AUDIT_STRICT=1` — fails the image build on any flagged CVE. Off by default for iterative local rebuilds; intended for CI.
- **Dependency CVE floors** declared in `requirements.txt`:
  - `transformers>=5.0,<6.0` — CVE-2026-1839 (RCE via malicious checkpoint).
  - `langchain-core>=1.4,<2.0`, `langchain>=1.0,<2.0` — CVE-2025-68664 (LangGrinch, CVSS 9.3).
  - `cryptography>=46.0.7,<47.0` — CVE-2026-26007, CVE-2026-39892.
  - `requests>=2.32,<3.0` — CVE-2024-35195, CVE-2024-47081.
  - `bleach>=6.2,<7.0` — bleach 5.x XSS bypass series.
  - `pillow>=12.2,<13.0` (declared explicitly, not just transitive) — CVE-2025-48379, CVE-2026-25990, CVE-2026-40192.

### Removed

- **Unmaintained / unused dependencies trimmed from `requirements.txt`** (with inline removal comments retained for institutional memory):
  - `pyPdf2` — abandoned 2022, replaced with `pypdf>=5.1,<6.0` (maintained successor).
  - `tensorflow-gpu` — discontinued post-TF 2.0.
  - `tensorflow-estimator` — deprecated; removed from TF 2.16+.
  - `tensorflow-addons` — deprecated by the TF team in 2024.
  - `trax` — last release 2021; conflicts with modern `jax>=0.4`.
  - `imgaug` — abandoned 2020 (use `albumentations`, already installed).
  - `selenium`, `webdriver-manager` — no Chrome/Firefox in the image.
  - `libclang` — legacy TF 2.15 transitive, unused.
  - `virtualenv` — redundant inside a `uv`-managed venv.
  - bare `black` — consolidated into `black[jupyter]>=26.0,<27.0`.
- **`LICENSE` file.** Removed in this cut. The README's MIT badge currently has no on-disk counterpart — flagged as a follow-up.

### Known issues

- `env.example` is referenced by the README's "Adding a new project" section but is currently deleted from the working tree. The `install.sh` wizard writes `.env` directly from prompt answers, so this does not block onboarding — but users who skip the installer and follow the README manually will hit a missing file.
- `LICENSE` file absent despite MIT badge in README.

## [Initial] — 2026-05-27

Repository bootstrap. Single file: `LICENSE` (MIT). No project content.

[Unreleased]: https://github.com/keduka/kedulab/compare/v0.0.1+20260528...HEAD
[v0.0.1+20260528]: https://github.com/keduka/kedulab/releases/tag/v0.0.1+20260528
[Initial]: https://github.com/keduka/kedulab/commit/db5a94527ad64784c0920310509b1e9ada35493f
