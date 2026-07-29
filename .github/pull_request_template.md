<!--
Keep the PR scoped to one concern. Delete sections that don't apply.
-->

## What breaks without this

<!-- The user-visible symptom, not the diff. "nltk.download() fails on the
     read-only rootfs" beats "adds NLTK_DATA". -->

## How it was verified

<!-- Exact commands and their output. If something could not be verified
     (no GPU, no daemon, build too slow), say so — do not imply it was. -->

```
bash tests/run_all.sh
```

## Checklist

- [ ] A failing test was written first, and it now passes
- [ ] `bash tests/run_all.sh` is green
- [ ] Shell changes pass `shellcheck --severity=warning`

If dependencies changed:

- [ ] The matching `requirements*.txt` **and** `pyproject.toml` were both updated
- [ ] Pins use `>=X.Y,<Z.0` — no bare names, no `==`
- [ ] Any ceiling that moved is explained below, with evidence (`uv pip compile`)

If compose changed:

- [ ] The same field was added to **both** `docker-compose.yml` and `docker-compose.cpu.yml`
- [ ] `diff <(docker compose config) <(COMPOSE_FILE=docker-compose.cpu.yml docker compose config)` shows only the GPU reservation

If a documented knob, default, or behaviour changed:

- [ ] `README.md`, `CLAUDE.md` and `.env.example` were updated to match

## Notes for the reviewer

<!-- Rationale for ceilings moved, known limitations, follow-up work. -->
