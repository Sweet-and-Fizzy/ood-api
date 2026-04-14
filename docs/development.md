# Development Environment

## Prerequisites

- Docker
- The `ondemand` repo cloned (e.g., at `~/Sites/ood/ondemand`) on the `master` branch
- The `ood-api` repo cloned separately

## Setup

### 1. Symlink ood-api into the ondemand dev directory

```bash
mkdir -p ~/ondemand/dev
ln -sf /path/to/ood-api ~/ondemand/dev/ood-api
```

### 2. Install ondemand Rakefile dependencies

```bash
cd /path/to/ondemand
bundle config --local path vendor/bundle
bundle install
```

### 3. Start the OOD dev container

The standard `rake dev:start` doesn't work on macOS without modifications.
Use `docker run` directly with the flags documented below.

```bash
cd /path/to/ondemand
CONTAINER_RT=docker rake dev:start
```

First run prompts for a Dex password (used for `<your-user>@localhost`).
First run also builds the `ood-dev:latest` image from `Dockerfile.dev`
(several minutes).

**Known issue — systemd on Docker Desktop for Mac:** The default container
flags use `--tmpfs /run -v /sys/fs/cgroup:/sys/fs/cgroup:ro` which doesn't
give systemd enough access to start services. You need `--privileged`,
`--cgroupns=host`, and cgroups mounted read-write. After the first
`rake dev:start` builds the image, stop the container and restart manually:

```bash
CONTAINER_RT=docker rake dev:stop
docker run -p 8080:8080 -p 5556:5556 \
  --name ood-dev --rm --detach \
  --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /tmp \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v ~/.config/ondemand/container/config:/etc/ood/config \
  -v ~/ondemand:$HOME/ondemand \
  -v /path/to/ood-api:/path/to/ood-api \
  ood-dev:latest
```

The extra `-v /path/to/ood-api:/path/to/ood-api` mount is needed because
the symlink at `~/ondemand/dev/ood-api` points to the ood-api source tree,
which lives outside `~/ondemand/` and wouldn't otherwise be visible inside
the container.

**Known issue — macOS UID < 1000:** OOD's `nginx_stage` rejects users with
UID below 1000 ("user is special"). macOS assigns regular users UIDs
starting at 501. Fix by creating `nginx_stage.yml` in the config directory:

```bash
cat > ~/.config/ondemand/container/config/nginx_stage.yml << 'EOF'
---
min_uid: 500
EOF
```

**Known issue — dev app symlink path mismatch:** The Dockerfile creates
`/home/<user>/ondemand/dev/` inside the container, but the Rakefile mounts
`~/ondemand` at its host-absolute path (e.g., `/Users/drew/ondemand`). The
gateway symlink at `/var/www/ood/apps/dev/<user>/gateway` points to
`/home/<user>/ondemand/dev`, which doesn't match the mount. Fix inside the
container:

```bash
docker exec ood-dev bash -c \
  "rm -rf /home/<user>/ondemand/dev && ln -sf /Users/<user>/ondemand/dev /home/<user>/ondemand/dev"
```

### 4. Install ood-api gems inside the container

```bash
docker exec -u <user> ood-dev bash -c \
  "cd /path/to/ood-api && bundle config --local path vendor/bundle && bundle install"
```

### 5. Verify

Open `https://localhost:8080/` in a browser (HTTPS with a self-signed
cert — accept the browser warning). Log in with `<your-user>@localhost`
and the password from step 3.

Navigate to `https://localhost:8080/pun/dev/ood-api/health`.

First visit will show "App has not been initialized." Click "Initialize App"
or navigate to the init URL — the PUN restarts and loads ood-api.

**Dev app URL pattern:** `/pun/dev/<app-name>/`, not `/pun/dev/<user>/<app-name>/`.
The owner is implicit from the logged-in session.

## Common tasks

| Task | Command |
|------|---------|
| Start container | See step 3 above (manual `docker run`) |
| Stop container | `docker stop ood-dev` |
| Shell into container | `docker exec -it -u <user> ood-dev bash` |
| Rebuild image | `CONTAINER_RT=docker rake dev:rebuild` |
| View container logs | `docker logs ood-dev` (empty for systemd containers) |
| Restart Passenger app | `touch /path/to/ood-api/tmp/restart.txt` (inside container) |

## Container details

- OOD portal: `https://localhost:8080/` (self-signed cert)
- Dex IdP: `http://localhost:5556/`
- PUN logs: `/var/log/ondemand-nginx/<user>/error.log` (inside container)
- Apache logs: `/var/log/httpd/` (inside container)
- Config: `~/.config/ondemand/container/config/` (host, mounted at `/etc/ood/config`)

## Teardown

```bash
docker stop ood-dev
```
