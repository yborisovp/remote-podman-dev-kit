# Download, unpack and go

Download the ready-to-use archive from the [latest GitHub Release](https://github.com/yborisovp/remote-podman-dev-kit/releases/latest). GitLab CI also tests this kit and publishes `dist/remote-dev.tar.gz` in the **package** job artifacts. Extract it into your repository and run `./remote-dev/dev.sh`. Rename or move the single `remote-dev/` directory as needed. Build locally with `bash scripts/package.sh`.

Compose discovery prefers the directory containing `dev.sh`, then its parent. Set `PROJECT_DIR` in `config/dev.env` for any other location (absolute or relative to the kit). Compose paths are relative to that project root, which is uploaded to Linux. Configuration and runtime state stay inside the kit and are excluded from uploads. Close tunnels before moving the kit.

Full installation accepts an administrative SSH alias or `user@host` on Debian/Ubuntu. It uses existing SSH configuration and interactive sudo when needed. No direct root SSH login is required. Leave `SSH_PORT` empty to honor the alias port. First ensure `ssh your-alias` works using an existing key or password. The installer creates and authorizes a separate project key automatically; add it to ssh-agent if passphrase-protected before running noninteractive check/start commands. Existing-user setup preserves existing SSH authentication without creating another key. New project connections use `project-user@your-alias`, retaining alias host/proxy settings.

See [the updated Russian guide](README.RU.md) for configuration, operation, limitations and tests.

## GitHub release automation

Every push to `main` and PR targeting `main` is verified on Ubuntu and macOS. A separate trusted `workflow_run` publisher releases the verified archive and SHA-256:

- `main`: stable `vX.Y.Z`, based on whole words in commit messages since the last stable tag. `major` wins over `minor`, which wins over `patch`; no marker defaults to patch. Lower components reset on major/minor bumps. Examples: `[major] Change config`, `[minor] Add feature`, `[patch] Fix login`. PR text only counts when included in a merged commit message.
- PR: a unique `pr-<number>-build-<run_id>-<attempt>` prerelease for each successful attempt, including forks. It identifies the tested PR head commit, never becomes Latest, and never affects stable version numbering. Only install previews from contributors you trust.

Stable publication is serialized; assets are uploaded to a draft before publication. Re-running **Actions → Verify and package → Run workflow** on `main` recovers an unfinished publication and leaves existing published releases unchanged. A superseded main build is skipped; the next successful current build includes accumulated changes. CI artifacts expire after 14 days; release assets remain available.

No PAT is required. Only the publisher has `contents: write` through `GITHUB_TOKEN`; it executes trusted main scripts and never extracts or executes PR archives. Repository rules must permit Actions and creation of release tags by that token. Publication is performed in the same workflow as tag creation, avoiding reliance on token-generated events triggering another workflow.

Run `bash scripts/verify.sh` locally (Python 3 and PyYAML required). GitLab CI uses the same checks and produces an artifact without publishing releases. CI does not exercise a real Debian installation.

## Reference

Run **your Compose project's services** on a rootless Linux Podman host from macOS or Windows RDP / Git Bash. Source and commands travel over SSH; published TCP ports are forwarded to workstation localhost.

[Русская инструкция](README.RU.md)

```bash
./dev.sh
```

Choose **Server setup → Full installation**, then **Check connection** and **Start services + tunnels**. Use arrows or j/k, a number to select a row, Enter to confirm, and q to return. In the service picker, numbers toggle services, a selects all, n clears selection. Enter returns to the menu after each action. `NO_COLOR=1 ./dev.sh` disables colors.

## Put it in your project

Extract the release archive into the repository. It contains one movable `remote-dev/` folder. Keep the scripts, `lib/` and `config/` together inside it. Compose may live beside `dev.sh` (preferred) or in the parent folder. Use `PROJECT_DIR` for other layouts.

Discovery accepts `compose.yaml`, `compose.yml`, `docker-compose.yaml`, or `docker-compose.yml`. Missing or ambiguous files stop startup with an explanation. Set `COMPOSE_FILE` to choose an explicit project-relative path. Automatic discovery also includes one conventional `compose.override.yaml/yml` or `docker-compose.override.yaml/yml`. When setting an explicit main file, specify the override with `COMPOSE_OVERRIDE`.

**Services come exclusively from Compose.** The old `examples/services.conf` format was removed; there is no fallback to demonstration services. You do not need `examples/` or `tests/` in your own repository. Merge this kit's `.gitignore` rules into your repository's existing file.

To try the sample in this folder, copy `examples/compose.yaml` to the kit root as `compose.yaml`, create `.env` containing `POSTGRES_PASSWORD=<your-password>`, and open the menu. Do not overwrite an existing application Compose file with this example.

## Requirements and first setup

The workstation needs Bash 3.2+, OpenSSH and tar, available in macOS Terminal and Git Bash. It does not need a local Docker Engine, Podman, Compose, Python, WSL or virtual machine. `nc` is optional for preliminary local port checks; SSH performs the final bind check.

Linux needs rootless Podman, its user socket, a Compose provider (`docker-compose` or `docker compose`), Python 3, and `python3-yaml` for Compose v1. The provider connects to the project user's Podman Unix socket. Docker Engine is not used to run project services. Support for individual Compose features depends on the installed provider and Podman.

Setup creates `config/dev.env` and derives `PROJECT_NAME` from the folder name. Ensure that the project name is unique within the Linux account. Use separate Unix accounts for different developers or trust boundaries.

**Full installation:** choose **Server setup → Full installation**, enter the administrative SSH target (sudo or root) and project username, then review and confirm the server changes. The local username is proposed; Git Bash also lists `/c/Users` profile names.

On Debian/Ubuntu with systemd, setup:

1. Logs in with existing SSH credentials, elevates with interactive sudo when needed, and checks mandatory TCP endpoints from `config/required-endpoints.conf`, using `nc` or timed Bash `/dev/tcp`. A failure stops setup before package installation.
2. Installs missing Podman/rootless dependencies, Python 3/PyYAML, `docker.io`, and Compose through apt. It enables the Docker service as part of full installation; the project user is not added to the root-equivalent docker group.
3. Creates or prepares the Linux user and home directory, sets Bash, and assigns free subordinate UID/GID ranges of at least 65,536 IDs when needed.
4. Adds the workstation's Ed25519 public key with secure permissions, enables linger, and starts the user's Podman socket. It does not set or change the Linux account password.
5. Updates `PODMAN_HOST` to the project account and verifies rootless mode.

Setup does not change root SSH policy. Verify the server fingerprint on first login. Use a key passphrase and load the key into `ssh-agent`; passwords/passphrases are not saved. Setup is not transactional: earlier steps remain after a failure; resolve the error before retrying.

For an already prepared account, choose **Server setup → Connect existing user** and enter `user@host` or an SSH alias.

## Manual Linux account provisioning

For administrators preparing Debian/Ubuntu without full installation:

```bash
sudo apt-get update
sudo apt-get install -y podman uidmap slirp4netns fuse-overlayfs dbus-user-session openssh-server python3 python3-yaml docker-compose
sudo useradd --create-home --shell /bin/bash myapp-dev
```

Check `/etc/subuid` and `/etc/subgid`. If there is no suitable range, assign an unused range of at least 65,536 IDs. The example allocation below is valid **only after confirming that it overlaps no existing allocation**:

```bash
grep '^myapp-dev:' /etc/subuid /etc/subgid
sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 myapp-dev
sudo loginctl enable-linger myapp-dev
```

Install the workstation public key into `/home/myapp-dev/.ssh/authorized_keys`: the directory must be owned by `myapp-dev` with mode 700, and the file with mode 600 and the same owner. Keep the private key on the workstation. This provides initial login without setting a password for the new account. Then choose **Connect existing user**; setup enables the user socket and verifies that `podman info --format '{{.Host.Security.Rootless}}'` returns `true`.

## Runtime behavior

Startup uploads a protected source snapshot, asks the remote Compose provider to resolve variables, merge overrides and normalize the model, then lists its actual services. Dependencies are included; services may publish several TCP ports or no ports.

The adapter writes a separate normalized Compose file with every published port bound to server `127.0.0.1`. The original file is unchanged. Explicit `container_name` values are removed so Compose uses project-scoped names. Compose builds and starts selected services and dependencies remotely, then SSH forwards their published ports.

For example, `8080:80` becomes server `127.0.0.1:18080:80` with the default `REMOTE_PORT_OFFSET=10000`; the workstation uses `127.0.0.1:8080`. `expose` does not create a tunnel. Duplicate published ports are rejected; occupied ports are detected during container startup or SSH binding.

Before starting a new selection, choose **Stop all services (keep volumes)**. This runs Compose `down` without deleting named volumes. Stopping selected services runs `stop`; the shared tunnel closes. **Close tunnel only** leaves containers running. Status and Stop use the saved remote model even if the local Compose file has changed.

## Configuration

`config/dev.env` uses plain `KEY=value` lines, not executable shell code. Do not quote values.

| Setting | Meaning |
|---|---|
| `PODMAN_HOST` | First setting: project-user SSH target or alias. |
| `ROOT_HOST` | Optional administrative SSH target (sudo or root) for full setup. |
| `SSH_PORT` | Empty uses OpenSSH configuration; an explicit value overrides the alias port. |
| `SSH_KEY` | Local private-key path, filled by setup. |
| `PROJECT_NAME` | Unique lowercase Compose project name; letters, digits, `_`, `-`. |
| `REMOTE_BASE` | Relative path under the Linux home; default `.cache/remote-podman-dev`. |
| `COMPOSE_FILE` | Empty for discovery in the chosen project root, or an explicit relative file. |
| `COMPOSE_OVERRIDE` | Additional Compose file. |
| `REMOTE_PORT_OFFSET` | Added to each published port for its server port; default 10000. Server ports must be within 1024–65535. |
| `REQUIRED_ENDPOINTS_FILE` | Mandatory `host\|port\|description` checks for full setup; default `config/required-endpoints.conf`. |

Before startup, registry TCP access is checked for selected image-only services. Add Dockerfile base-image registries and package feeds to the mandatory endpoint file yourself. TCP checks do not verify TLS, credentials or HTTP; pull/build failures are reported separately. Local shell variables are not automatically sent to Linux: use the project's `.env` or `env_file`.

## Source transfer and limits

**`.env`, `env_file`, and file-based secrets are uploaded over SSH to the project account.** The normalized Compose model can contain secrets and is stored with mode 600. Snapshots are created under `umask 077`; the account must be trusted with those secrets.

Transfer excludes `.git`, `.runtime`, `config/dev.env`, `node_modules`, `bin`, `obj`, and `__pycache__`. Add tar exclusion patterns to `.devkitignore` when needed; do not exclude required Compose/build inputs. Use `.dockerignore` in build contexts as appropriate.

Build contexts, file-based secrets/configs, and bind mounts must stay inside the uploaded project. Workstation absolute paths, external directories, remote/additional build contexts, and SSH build forwarding are unsupported. Server snapshots are retained for diagnosis and are not automatically removed. Bind mounts point into snapshots; remote changes are not synchronized back. Use named volumes for persistent data. Live reload needs a separate synchronization mechanism.

Host/container networking, published UDP, port ranges and random published ports are rejected. Profiles are enabled for enumeration; only selected services and dependencies are started. This is a development kit. Partial `up` failures do not roll back automatically; use Status and Stop all. After an abrupt termination, `.runtime/operation.lock` may need manual removal after confirming no operation is still running.

## Validation

```bash
bash tests/smoke.sh
python3 tests/ui_smoke.py
python3 -m unittest discover -s tests -p 'test_*.py'
```

Python is needed for local tests, not for the launcher. Smoke tests execute the real remote adapter in a temporary directory with mocked SSH/Compose, covering discovery, dependencies, multiple ports, transfer, startup/shutdown and tunnels. UI tests use a macOS/Linux pseudo-terminal. These do not verify a live Linux host, Podman API, or Windows RDP. Optional lint: `shellcheck dev.sh setup.sh lib/ui.sh tests/smoke.sh`.

Sources: [Compose config](https://docs.docker.com/reference/cli/docker/compose/config/), [Podman Compose providers](https://docs.podman.io/en/latest/markdown/podman-compose.1.html), [rootless Podman](https://docs.podman.io/en/latest/markdown/podman.1.html#rootless-mode).
