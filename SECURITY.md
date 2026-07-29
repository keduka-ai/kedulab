# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue.

Use GitHub's private vulnerability reporting: go to the repository's
**Security** tab → **Report a vulnerability**. That opens a private advisory
visible only to you and the maintainers.

> Maintainers: private reporting has to be switched on once, under
> *Settings → Code security and analysis → Private vulnerability reporting*.
> If you would rather take reports by email, add the address here.

Please include the affected file or dependency, what an attacker can do, and
the steps to reproduce. We aim to acknowledge within a few working days.

## What is in scope

This project ships container build definitions and an installer, not an
application, so the interesting surface is narrower than usual:

- **Container hardening regressions** — anything that reintroduces root,
  removes `cap_drop: [ALL]`, disables `read_only`, or widens the port bind.
- **`install.sh`** — it is designed to be piped into `bash`, so command
  injection, unsafe path handling, or fetching over an unverified channel are
  in scope.
- **Dependency pins** — a CVE that the ranges in `requirements*.txt` or
  `jupyter-base.txt` fail to exclude. Include the CVE ID and the fixed version.
- **Secret exposure** — anything causing credentials or tokens to be written
  into the image, the build context, or logs.

Out of scope: vulnerabilities in upstream packages that our pins already
exclude, and anything that requires the operator to have already disabled the
documented defaults (for example, running with `BIND_ADDR=0.0.0.0` and no
password — see below).

## Deployment expectations

The defaults assume **a single trusted user on their own machine**:

- JupyterLab binds `127.0.0.1` only. It is arbitrary code execution by design —
  anyone who can reach the port can run anything as the container user.
- `BIND_ADDR=0.0.0.0` is supported but **requires** `JUPYTER_PASSWORD_HASH`, and
  should sit behind a TLS-terminating auth proxy. Exposing it directly to a
  network you do not control is not a supported configuration.
- The workspace bind mount is read-write by design; notebooks can write
  anywhere under it, including the pip overlay at `.kedulab-packages`, which is
  searched *before* the image's pinned virtualenv.

## Verifying the installer

`curl … | bash` runs whatever is on the branch at that moment. To make the
install reviewable and reproducible:

```bash
curl -fsSLO https://raw.githubusercontent.com/keduka-ai/kedulab/main/install.sh
sha256sum install.sh      # compare against the checksum in the release notes
less install.sh           # read it
bash install.sh --ref v1.2.3   # pin an immutable tag
```

`--ref` defaults to `main`, a moving branch; the installer warns when it is
given a ref that is not a tag.

## Reproducible builds

Two mutable inputs are pinned separately from the Python dependency ranges:

- **The base image.** `scripts/pin-base.sh` resolves
  `nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04` to a digest and writes
  `BASE_IMAGE=nvidia/cuda@sha256:…` into your env file.
- **The transitive dependency set.** `scripts/lock.sh -a` compiles
  hash-verified lockfiles; building with `REQUIRE_HASHES=1` makes the install
  reject anything whose hash does not match.

See the README section *Reproducible builds* for the full sequence.

## The CVE gate

`PIP_AUDIT_STRICT=1` runs `pip-audit --strict` as part of the build and fails
it on any flagged advisory in the resolved set. It is off by default so local
rebuilds are not blocked by an unpatched transitive, and on in CI — the
`Security` workflow builds weekly with the gate enabled.
