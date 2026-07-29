# Kedulab v0.1.5+20260728 — in-notebook installs, librosa

**Released:** 2026-07-28

You can now install a library from inside a notebook. `!pip install <lib>` previously failed on every stack, for two independent reasons, and both are fixed. `librosa` also joins the default image. **This release requires a rebuild** (`docker compose -p <project> up -d --build`) — the fix touches both the image and the entrypoint.

## Fixed

- **`!pip install <lib>` failed with `pip: not found`.** The venv is created by `uv venv`, which does not seed pip, so no `pip` binary existed on `PATH`. `%pip install` failed the same way (`No module named pip`). `pip>=26.1,<27.0` is now pinned in `jupyter-base.txt`. Build-time installs are unchanged — they still go exclusively through `uv pip install -r <file>`; pip is present only to serve the interactive path.
- **Even with pip present, there was nowhere to write.** The compose service sets `read_only: true` and the venv lives at `/opt/venv` on that rootfs, so an install would have failed on a read-only filesystem. `scripts/entrypoint.sh` now provisions a writable install prefix at runtime and points pip at it.

## Added

- **In-notebook installs.** `!pip install <lib>` and `%pip install <lib>` both work; restart the kernel and import. The entrypoint asks `sysconfig` for the `purelib` / `platlib` / `scripts` paths that pip's `--prefix` will write to, creates them, then exports `PIP_PREFIX` and prepends the site-packages dir to `PYTHONPATH` and the scripts dir to `PATH`. Kernels inherit the server's environment, so both install paths land in the same place.
- **`KEDULAB_USER_PREFIX`** (default `/home/workspace/.kedulab-packages`) — where those installs go. It sits on the bind-mounted workspace, which has three consequences worth knowing: installs **survive a container restart**, they can be **wiped from the host** with `rm -rf <MOUNT_PATH>/.kedulab-packages` to get back to exactly what the image ships, and a **rebuild does not clear them**. Set the variable to an empty string to disable in-notebook installs entirely. Passed through in both compose files with `${VAR-default}` (no colon) so an explicitly empty value isn't silently replaced by the default.
- **`librosa>=0.11,<1.0`** in `requirements.txt` and `pyproject.toml`. Verified against the full pin set with `uv pip compile` before adding: it resolves to librosa 0.11.0 / numba 0.66.0 with numpy landing on 2.0.2 — inside TF 2.18's `>=1.26,<2.1` window — so no existing ceiling had to move. Decoding beyond WAV/FLAC goes through `audioread` → `ffmpeg`, already an apt dependency.

## Notes on the implementation

Three details are load-bearing and are documented in `CLAUDE.md` so they don't get regressed:

- **pip runs with `--prefix`, never `--target`.** `--target` implies `--ignore-installed`: it re-resolves every transitive dependency into the overlay. Measured directly — a `--target` install pulled a fresh `packaging 26.2` in despite the venv already carrying 24.2. Applied to `!pip install librosa`, that would have dropped a newer numpy on top of the pinned one and broken TensorFlow. `--prefix` treats `/opt/venv` as satisfying and fetches only what is genuinely missing.
- **The prefix directory is created at runtime, not at build time.** It lives under `/home/workspace`, which is the bind-mount target — anything `mkdir`'d there in the Dockerfile is masked once the mount lands.
- **Paths come from `sysconfig`, not string concatenation.** Hand-building `lib/python${PYTHON_VERSION}/site-packages` breaks when `PYTHON_VERSION` is given as `3.12.4` rather than `3.12`, and on Debian-patched interpreters that use `dist-packages`.

Failure is never fatal: if the workspace mount isn't writable by the container user, the entrypoint warns to stderr and starts JupyterLab anyway — you lose ad-hoc installs, not the server.

**Known limitation:** the overlay precedes `/opt/venv` on `sys.path`, so a deliberate `!pip install numpy==2.2` *can* shadow a pin and break the framework stack. Recovery is to delete the overlay directory from the host and restart. `!uv pip install` still does not work at runtime — uv targets `/opt/venv` directly, which is read-only. Use `pip`.

## Changed

- **Docs** — README gains an *Installing libraries from a notebook* section, the `KEDULAB_USER_PREFIX` row in the configuration table, and four troubleshooting entries (`pip: not found`, read-only/permission failures, a missing overlay after a `MOUNT_PATH` change, and recovering from a shadowed pin). `CLAUDE.md` documents the mechanism and its constraints. Three pre-existing inaccuracies were corrected along the way: the pin ceilings were listed as `numpy<2.2` and `gradio<6.0` (actual: `<2.1` and `>=6.12,<7.0`), and the healthcheck was described as polling `localhost:5678/api/status` (it polls `/login` on `JUPYTER_PORT`).

## Tests

- Added `tests/notebook_install_test.sh` — asserts the pip pin, the entrypoint's `PIP_PREFIX` / `PYTHONPATH` / `PATH` wiring against the paths `sysconfig` reports, preservation of a pre-existing `PYTHONPATH`, graceful degradation on both an unwritable prefix and a failed interpreter query, the empty-string disable knob, librosa's presence in both dependency files, and continued GPU/CPU compose lockstep. Runs without a Docker daemon (stub `python` / `jupyter-lab` binaries; `docker compose config` parses client-side). Fails against the pre-fix tree and passes against the fix.

## Upgrade

Pull the latest `main` (or `--ref v0.1.5+20260728`) and rebuild: `docker compose -p <project> up -d --build`. A rebuild is required — without it the image still has no `pip`. Nothing to change in existing `.env` files; `KEDULAB_USER_PREFIX` defaults sensibly and the overlay directory is created on first boot. Note that ad-hoc installs are deliberately **not** reproducible: once a library earns its place, add it to the project's `requirements*.txt` (and `pyproject.toml`) and rebuild.

---

# Kedulab v0.1.4+20260529 — CPU fallback

**Released:** 2026-05-29

Kedulab now runs without a GPU. Previously the installer aborted and the compose service refused to start on a GPU-less host; both now detect the absence of a GPU, inform the user, and default to CPU. **Existing GPU stacks are unaffected — they rebuild identically** (the GPU `docker-compose.yml` is still the default).

## Added

- **`docker-compose.cpu.yml`** — a self-contained CPU variant of `docker-compose.yml` with the `deploy.resources.reservations.devices` nvidia block removed. The same CUDA-based image is reused; TensorFlow / PyTorch / JAX fall back to CPU at runtime (slower, but fully functional). Selected via the native `COMPOSE_FILE` var, not a `-f` override merge — Compose can't reliably clear a device reservation through merge (verified with `docker compose config`), so the CPU config is spelled out in full and kept in lockstep with the GPU file.
- **`KEDULAB_GPU` installer override** — `auto` (default, probe for a GPU), `on` (force GPU), or `off` (force CPU).

## Changed

- **`install.sh` no longer hard-fails when no GPU is found.** The GPU smoke test moved out of the hard prerequisite check into a soft `detect_gpu()` step: on a miss it warns, links the NVIDIA Container Toolkit guide, and defaults to CPU by writing `COMPOSE_FILE=docker-compose.cpu.yml` into the generated `.env`. The next-steps banner notes when CPU mode was selected. Docker / Compose v2 remain hard requirements.
- **Docs** — README prerequisites now mark a GPU as recommended (not required) and add a *CPU fallback* section; the device-driver troubleshooting entry and the "I want a CPU-only variant" FAQ point at `docker-compose.cpu.yml`. `CLAUDE.md` documents the file, the `COMPOSE_FILE` mechanism, and the lockstep rule. *(The earlier "CPU-only use is not supported" note in v0.1.0 is superseded.)*

## Tests

- Added `tests/gpu_fallback_test.sh` — mocks the `docker` GPU probe and asserts that a no-GPU install exits cleanly (not `1`), informs the user, and pins `COMPOSE_FILE=docker-compose.cpu.yml`, while a GPU install leaves `.env` on the GPU default. Reproduces the old hard-exit against the pre-fix behavior and passes against the fix.

## Upgrade

Pull the latest `main` (or `--ref v0.1.4+20260529`). GPU users: nothing changes — the default compose file still reserves the GPU. CPU users: re-run the installer (it now auto-selects CPU), or set `COMPOSE_FILE=docker-compose.cpu.yml` in `.env`. If you keep a per-project env file, add a commented `COMPOSE_FILE` line from the updated `.env.example`.

---

# Kedulab v0.1.3+20260529 — installer terminal release

**Released:** 2026-05-29

A bugfix release for the `install.sh` bootstrap. No image, dependency, or runtime behavior changes — existing stacks rebuild identically.

## Fixed

- **The streamed installer no longer hangs after the next-steps command is echoed.** `open_tty` opened the controlling terminal with `exec </dev/tty`, rebinding the script's own `fd 0`. Under `curl … | bash` — where bash reads the script body from `fd 0` — this left bash reading the *next* command from the keyboard after `main()` returned, so the installer appeared to finish but never returned the shell. Prompts now read from a dedicated `fd 3`, leaving `fd 0` (the script pipe) untouched; bash hits EOF and exits cleanly. The TTY fd is explicitly closed once configuration finishes (`release_tty`), and the script ends with an explicit `exit 0`.
- **`git clone` fails fast instead of blocking on a credential prompt.** A clone against a private, typo'd, or expired remote previously stalled forever at git's interactive `Username:` prompt on `/dev/tty`, hanging the install at the clone step. The clone now runs with `GIT_TERMINAL_PROMPT=0` and stdin detached — configured credential helpers still work, only the interactive fallback is disabled.
- **Prerequisite probes can no longer grab the terminal.** The `docker version` / `docker compose version` checks and the GPU smoke test (`docker run … nvidia-smi`) now run with stdin detached (`</dev/null`).

## Tests

- Added `tests/install_terminal_test.sh` (clone credential fail-fast) and `tests/install_release_test.sh` + `tests/pty_release.py` (terminal release after a full streamed interactive install, driven through a real pty). Both reproduce the hang against the pre-fix behavior and pass against the fix.

## Upgrade

Pull the latest `main` (or `--ref v0.1.3+20260529`). Nothing to rebuild — the change is confined to `install.sh`. If you cached the one-liner, re-fetch it.

---

# Kedulab v0.1.2+20260528 — general-purpose repositioning

**Released:** 2026-05-28

A documentation and housekeeping release. No image, dependency, or runtime behavior changes — existing stacks rebuild identically.

## Changed

- **Repositioned as a general-purpose tool.** Kedulab is now documented as a general-purpose GPU JupyterLab launcher adaptable to any project, rather than as Keduka AI School infrastructure specifically. The README tagline and `About` section lead with the general use case; Keduka Cognitive Services remains the maintainer and KAIS is presented as one consumer (it ships the `requirements-kais.txt` extras), not the sole target audience.

## Housekeeping

- **`.gitignore` / `.dockerignore` expanded** to keep notebook checkpoints, trash, and other local workspace artifacts out of the repo and the build context.
- **Stray workspace artifacts removed** from version control (`workspace/Untitled.ipynb`, `.ipynb_checkpoints/`, `.Trash-1000/`).

## Upgrade

Pull the latest `main` (or `--ref v0.1.2+20260528`). Nothing to rebuild for the change itself; the next `docker compose up -d --build` picks up the trimmed build context.

---

# Kedulab v0.1.0+20260528 — first release

**Released:** 2026-05-28

Kedulab is the container infrastructure that powers the notebooks behind the [Keduka AI School](https://keduka.com) curriculum and internal research — a Docker Compose setup that spins up GPU-accelerated JupyterLab containers, one image per project, side-by-side, reproducible.

This is the first cut. Everything below works today on a Linux host with an NVIDIA GPU and the NVIDIA Container Toolkit installed.

## One-liner install

```bash
curl -fsSL https://raw.githubusercontent.com/keduka/kedulab/main/install.sh | bash
```

The installer verifies your host can run the stack (Docker, Compose v2, NVIDIA Container Toolkit, GPU smoke test), clones the repo, walks you through four prompts (project name, requirements file, mount path, host port — press enter for defaults), writes `.env`, and prints the exact `docker compose up` command to start the container. It does **not** auto-launch — you run the final command yourself.

Read it before piping if you'd like:

```bash
curl -fsSL https://raw.githubusercontent.com/keduka/kedulab/main/install.sh | bash -s -- --help
```

## What's in the box

- **GPU JupyterLab on CUDA 12.4.** Base image is `nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04`. TensorFlow 2.18, PyTorch 2.5/2.6 (CUDA 12.4 wheels), and JAX 0.4.x all co-installed against the base CUDA stack.
- **One image per project.** Pass `REQUIREMENTS_FILE=requirements-nlp.txt` to bake a separate image with a separate dependency set. Stacks run side-by-side via `docker compose -p <project>` without colliding.
- **`uv`-managed Python.** No conda, no Miniconda. Python (default 3.12) and packages installed via `uv` into `/opt/venv`; `uv` itself is pinned from `ghcr.io/astral-sh/uv:0.5.11`.
- **Two-tier requirements split.** `jupyter-base.txt` holds JupyterLab plumbing (always installed); `requirements.txt` holds default ML/NLP deps; `requirements-distributed.txt` adds Ray/Kubernetes/KFP; `requirements-kais.txt` carries KAIS-internal extras.
- **Interactive `install.sh` bootstrap.** Flags: `--ref`, `--dir`, `--yes`, `--no-prereq-check`. CI-friendly env-var overrides: `KEDULAB_PROJECT`, `KEDULAB_REQUIREMENTS_FILE`, `KEDULAB_MOUNT_PATH`, `KEDULAB_HOST_PORT`, `KEDULAB_REPO_URL`.
- **Reproducible-build helper.** `scripts/lock.sh` compiles any `requirements*.txt` to a hash-pinned lockfile via `uv pip compile --generate-hashes`; rebuild against `REQUIREMENTS_FILE=requirements.lock`.
- **Branded onboarding.** First-run walkthrough in the README with three screenshots showing the Launcher (with the custom `ml` kernel registered), the notebook rename context menu, and the rename dialog.

## Security defaults

Tuned for a single-user laptop out of the box. None of this is opt-in:

- **Loopback bind by default** (`BIND_ADDR=127.0.0.1`). JupyterLab on a public bind is arbitrary code execution; overriding this requires also setting `JUPYTER_PASSWORD_HASH`.
- **Non-root container user** (`jovyan`, UID/GID `1000:1000`, overridable to match host).
- **Locked-down compose service:** `cap_drop: [ALL]`, `no-new-privileges:true`, `read_only: true` rootfs with `tmpfs` for `/tmp`, `~/.jupyter`, `~/.local`, `~/.cache`, `~/.ipython`. Only the bind-mounted `/home/workspace` is persistently writable — a code-execution bug inside the container cannot persist a payload to the image rootfs.
- **Memory / CPU caps** (16G / 8 CPUs default).
- **Pinned `uv`** from the official GHCR image — no `install.sh` fetch at build time.
- **Opt-in `pip-audit` build gate** (`PIP_AUDIT_STRICT=1`) for CI.
- **Dependency CVE floors** enforced in `requirements.txt`:
  - `transformers>=5.0,<6.0` (CVE-2026-1839)
  - `langchain-core>=1.4,<2.0` (CVE-2025-68664 / LangGrinch, CVSS 9.3)
  - `cryptography>=46.0.7,<47.0` (CVE-2026-26007, CVE-2026-39892)
  - `requests>=2.32,<3.0` (CVE-2024-35195, CVE-2024-47081)
  - `pillow>=12.2,<13.0` (CVE-2025-48379, CVE-2026-25990, CVE-2026-40192)

## Quick start (post-install)

```bash
cd kedulab
docker compose --env-file .env -p kedulab up -d --build
docker compose -p kedulab logs -f jupyter   # grab the URL/token
```

Open the printed URL (`http://127.0.0.1:8888/lab?token=...`) in your browser. The `./workspace` directory on the host is mounted at `/home/workspace` inside the container — anything you save in JupyterLab lands there.

For multiple parallel stacks, see the README's "Running multiple stacks in parallel" section.

## Known issues

- **CPU-only use is not supported out of the box.** The compose service requires an NVIDIA GPU + Container Toolkit. CPU users need to fork or strip the `deploy.resources.reservations.devices` block manually.

## Compatibility

- **Tested on:** Linux + Docker Engine 24+ with Compose v2, NVIDIA driver compatible with CUDA 12.4, NVIDIA Container Toolkit installed.
- **Python:** 3.12 (default, overridable via `PYTHON_VERSION`).
- **Notable framework pins:** `tensorflow>=2.18,<2.19` (deliberate user-intent ceiling), `numpy>=1.26,<2.1` (TF 2.18's actual support window), `torch>=2.5,<2.7`, `jax[cuda12]>=0.4.38,<0.5`. See `CLAUDE.md` for the rationale behind each ceiling.

---

**Install:** `curl -fsSL https://raw.githubusercontent.com/keduka/kedulab/main/install.sh | bash`
**Repository:** https://github.com/keduka/kedulab
**Brand:** [Keduka AI School](https://keduka.com) · © Keduka Cognitive Services
