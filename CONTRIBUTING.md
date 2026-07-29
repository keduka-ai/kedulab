# Contributing

Thanks for taking the time. This repo has no application source — the artifacts
are container build definitions plus the requirements files that drive what goes
into them — so most contributions are small, high-leverage edits to a handful of
files. A few conventions keep them safe.

## Running the tests

```bash
bash tests/run_all.sh
```

Everything runs without a Docker daemon: the compose tests use
`docker compose config` (client-side only), the entrypoint tests drive
`scripts/entrypoint.sh` with stub `python` / `jupyter-lab` binaries, and the
installer tests mock `docker` and clone from a local bare repo. The suite
finishes in seconds.

The one exception builds the real image and is opt-in:

```bash
KEDULAB_RUN_SMOKE=1 bash tests/run_all.sh
```

## Tests come first

Write the failing test before the change. Every existing test encodes a
regression that actually happened — read the header comment of the nearest one
before adding to it, and put the *reason* in the failure message, not just the
assertion. A failure message that explains what breaks for the user is worth
more than the assertion itself.

Which file to add to:

| Change | Test |
| --- | --- |
| `scripts/entrypoint.sh` | `tests/cache_dirs_test.sh`, `tests/notebook_install_test.sh` |
| `docker-compose*.yml` | `tests/compose_test.sh` |
| `Dockerfile` | `tests/dockerfile_test.sh`, `tests/image_smoke_test.sh` |
| `install.sh` | `tests/install_env_test.sh`, `tests/gpu_fallback_test.sh`, `tests/install_*_test.sh` |

## Dependency changes

Read **CLAUDE.md § Dependency edits** first. The pins are not arbitrary — most
ceilings encode a resolver conflict and most floors encode a CVE. In short:

- Pin as `>=X.Y,<Z.0`. No bare names, no `==`.
- Edit the matching `requirements*.txt` **and** `pyproject.toml` together.
- Never add `jupyterlab`, `ipykernel` or `pip` to a project requirements file —
  they come from `jupyter-base.txt`.
- Build-time installs go through `uv pip install -r <file>`. Never add a raw
  `pip install <pkg>` to the Dockerfile.
- If you move a ceiling, say in the PR *why* the old one existed and what you
  verified. `uv pip compile` output is good evidence.

Some pins move as a set: `tensorflow`, `jax`, `ml-dtypes` and `numpy` share one
compatibility window, and `torch` is tied to the base image's CUDA version.

## Compose changes

`docker-compose.cpu.yml` is a full copy of `docker-compose.yml` minus the GPU
device reservation. Any field you add to one must be added to the other. Verify:

```bash
diff <(docker compose config) <(COMPOSE_FILE=docker-compose.cpu.yml docker compose config)
# expected: only the reservations.devices block differs
```

`tests/compose_test.sh` enforces this, and so does CI.

## Style

- Comment the *why*, not the *what*. The existing comments explain the failure
  that motivated each line — match that.
- Shell must pass `shellcheck --severity=warning`. CI runs it over `install.sh`,
  `scripts/*.sh` and `tests/*.sh`.
- `install.sh` gets piped into `bash` by real users. Quote everything, keep it
  POSIX-friendly where practical, and never add an unprompted network fetch.

## Pull requests

Keep them scoped to one concern. Say what breaks without the change, and how
you verified it — the exact command and its output. If you could not verify
something (no GPU, no daemon, a slow build), say so plainly rather than
implying it was tested.

## Security

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).
