# browseros-neo

[BrowserOS neo](https://github.com/browseros-ai/BrowserOS) packaged as a Docker image you can use from a web browser, in the style of [jlesage/docker-thunderbird](https://github.com/jlesage/docker-thunderbird).

- **Web GUI**: noVNC-based web UI served on port `9300` by [jlesage/baseimage-gui](https://github.com/jlesage/docker-baseimage-gui)
- **MCP**: BrowserOS neo's MCP server on `/mcp`, behind Bearer-token authentication. It is served by the same nginx as the web GUI, so it shares the web port by default (`WEB_LISTENING_PORT` and `MCP_LISTENING_PORT` both default to `9300`). Setting `MCP_LISTENING_PORT` to a different value gives MCP a port of its own.
- **Automatic builds**: a new `browserclaw/v*` release is detected and `ghcr.io/tinyrack-net/browseros-neo` is published automatically

## Quick start

```bash
export MCP_AUTH_TOKEN="$(openssl rand -hex 32)"
docker compose up -d
```

- GUI: <http://localhost:9300>
- MCP: <http://localhost:9300/mcp> (header `Authorization: Bearer $MCP_AUTH_TOKEN`)

Or with `docker run`:

```bash
docker run -d --name browseros-neo \
  --shm-size 2g \
  --security-opt seccomp=unconfined \
  -p 9300:9300 \
  -e MCP_AUTH_TOKEN="$MCP_AUTH_TOKEN" \
  -v "$PWD/config:/config" \
  ghcr.io/tinyrack-net/browseros-neo:latest
```

## Image tags

| Tag | Meaning |
| --- | --- |
| `latest` | Latest stable BrowserOS neo release |
| `<version>` (e.g. `0.51.1.2`) | That BrowserOS neo version. Overwritten when the image repo itself changes |

Only `linux/amd64` is supported, because BrowserOS neo ships its Linux build for amd64 only.

## Environment variables

On top of the base image's [environment variables](https://github.com/jlesage/docker-baseimage-gui#environment-variables) (`USER_ID`, `GROUP_ID`, `TZ`, `WEB_AUTHENTICATION`, `SECURE_CONNECTION`, `DISPLAY_WIDTH`, `DISPLAY_HEIGHT`, and so on), the following are available.

| Variable | Description | Default |
| --- | --- | --- |
| `WEB_LISTENING_PORT` | Web GUI port. The base image defaults to `5800`; this image defaults to `9300`, so the GUI and MCP share one port. `-1` disables the web listener. | `9300` |
| `MCP_AUTH_TOKEN` | MCP Bearer token. If empty, the MCP endpoint is disabled. At least 16 characters from `A-Z a-z 0-9 . _ ~ + / = -` | (empty) |
| `MCP_LISTENING_PORT` | MCP port. When it equals `WEB_LISTENING_PORT`, MCP is served on the web port at `/mcp` and no second listener is created. When it differs, MCP gets its own listener (plain HTTP). `-1` disables MCP. | `9300` |
| `BROWSER_SANDBOX` | Chromium sandbox: `auto` (on when user namespaces are available, otherwise `--no-sandbox`), `on`, `off` | `auto` |
| `KEEP_APP_RUNNING` | Restart the browser automatically if it exits | `1` |

`WEB_LISTENING_PORT` and `MCP_LISTENING_PORT` are resolved when the container starts, so changing them requires a restart.

## Ports

| Port | Purpose |
| --- | --- |
| `9300` | Web GUI (`/`), MCP (`/mcp`), health check (`/healthz`) — the default single port |
| `MCP_LISTENING_PORT` | Only when it differs from the web port: MCP (`/mcp`) and its health check live on this port instead, and the web port serves no MCP |
| `5900` | VNC (optional, provided by the base image) |

BrowserOS neo's internal ports (`9010` MCP, `9110` CDP, `9210` server) listen only on the container's loopback interface and are not exposed.

The health check `/healthz` answers on the web port when both ports are the same, and on the MCP port when they differ.

When MCP shares the web port it inherits that port's TLS setting, so with `SECURE_CONNECTION=1` the MCP URL is `https://<host>:9300/mcp`. A separate MCP port is always plain HTTP.

## Data

| Path | Contents |
| --- | --- |
| `/config/profile` | Browser profile (logins, cookies, extensions, BrowserOS neo settings and audit DB) |
| `/config/log` | Logs. MCP requests are logged with everything else in `/config/log/nginx/` |

Sessions and settings persist across container restarts and recreation, as long as `/config` is a volume.

## Web GUI window handling

BrowserOS neo draws its own window controls, including a minimize button, and it can have more than one window open (a new window, a popup, a dialog). A minimized window is unmapped and stops rendering, and the desktop has no taskbar and no window menu. The one key Openbox binds by default for switching windows (Alt+Tab) never reaches the browser either, because the operating system of whoever is watching the web GUI consumes it first. A minimized window would therefore be lost, leaving the GUI on a black, unclickable screen.

A `window-guard` service keeps every window of the application mapped:

- a window the window manager reports as minimized is mapped again,
- the window that was in front stays in front, so a restored window comes back behind it. Minimizing a window while another one is visible therefore shows the other window, and the minimized one can be brought back the same way,
- when no other window is left, the minimize is undone instead, so the GUI can never end up on an empty screen.

Windows are matched by WM_CLASS (`chromium-browser`) rather than by title, so a second window, a popup or a dialog is restored as well, while the application's internal windows (class `browserclaw`) are left alone. Only windows the window manager reports as hidden (`_NET_WM_STATE_HIDDEN`) are restored, so a window that was never shown stays hidden.

A `56-openbox-keys.sh` init script adds explicit switching keys to the Openbox configuration: `Ctrl+F6` and `Ctrl+Shift+F6` cycle forward and backward through the windows of the current desktop. It repeats `Alt+Tab` and `Alt+Shift+Tab` as well, because adding a `<keyboard>` section to the Openbox configuration replaces Openbox's built-in defaults.

## Connecting an MCP client

```json
{
  "mcpServers": {
    "browseros-neo": {
      "type": "http",
      "url": "http://<host>:9300/mcp",
      "headers": { "Authorization": "Bearer <MCP_AUTH_TOKEN>" }
    }
  }
}
```

### How MCP is served

BrowserOS neo's MCP server (`127.0.0.1:9010/mcp`) has no authentication of its own, and to prevent DNS rebinding it accepts only requests whose `Host` is `127.0.0.1` or `localhost`. The nginx that serves the web GUI therefore serves MCP as well:

1. it answers `/mcp` on the web port, or on `MCP_LISTENING_PORT` when that is a different port,
2. it rejects any request without a matching `Authorization: Bearer <MCP_AUTH_TOKEN>` header with `401`. The base image maps `401` to its login page when web authentication is enabled, so the MCP locations claim the code back and answer with a plain `401` challenge,
3. it rewrites `Host` to `127.0.0.1:9010` and strips the `Origin` and `Authorization` headers,
4. it disables buffering so SSE streams pass through, then forwards to `127.0.0.1:9010`.

The locations are generated at container start by `rootfs/etc/cont-init.d/55-mcp.sh` into `/var/tmp/nginx/mcp.conf` (web port) and `/var/tmp/nginx/mcp_site.conf` (own port). `scripts/patch-nginx-includes.sh` adds the include lines for them to the base image's nginx configuration at build time, and fails the build when the base image no longer looks the way it expects.

## Security notes

- Chromium's sandbox needs user namespaces, which Docker's default seccomp profile blocks. Run with `--security-opt seccomp=unconfined` (K8s: `securityContext.seccompProfile.type: Unconfined`) to enable the sandbox. Without it the browser falls back to `--no-sandbox` and shows a warning bar. With the fallback, renderer isolation is weak, so don't use it to browse untrusted sites.
  - `seccomp=unconfined` removes only the container's syscall filter. Namespaces, capability restrictions, and the non-root user stay in place, and Chromium applies its own seccomp-bpf filter to renderers.
- The web GUI has no authentication by default. Protect it with a reverse proxy or [web authentication](https://github.com/jlesage/docker-baseimage-gui#web-authentication) (`WEB_AUTHENTICATION=1` + `SECURE_CONNECTION=1`) before exposing it externally. With web authentication enabled the MCP endpoint still authenticates with its own Bearer token, so `/mcp` is not behind the login page.
- The MCP token is passed in plaintext over HTTP. When it crosses a network, put it behind a TLS-terminating reverse proxy.

## Build

CI (`.github/workflows/build.yml`):

| Trigger | Behavior |
| --- | --- |
| Pull request | Build the latest release + smoke test (no push) |
| Push to `main` | Build the latest release, test, and push `<version>` and `latest` |
| Daily schedule (03:17 UTC) | If the latest release has no GHCR tag yet, build, test and push it |
| `workflow_dispatch` | Specify `browseros_version` to rebuild that version (in this case `latest` is not updated) |

Local build:

```bash
eval "$(./scripts/resolve-release.sh)"          # or ./scripts/resolve-release.sh 0.51.1.2
docker build \
  --build-arg BROWSEROS_VERSION="$version" \
  --build-arg BROWSEROS_SHA256="$sha256" \
  -t browseros-neo:test .
./tests/smoke.sh browseros-neo:test
```

`scripts/resolve-release.sh` uses the `digest` field of the GitHub release asset as the SHA256. If the digest is missing, it downloads the file and computes it.
