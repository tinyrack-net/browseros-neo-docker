# syntax=docker/dockerfile:1

ARG BASEIMAGE=jlesage/baseimage-gui:debian-13-v4.14.0

FROM ${BASEIMAGE}

# BrowserOS neo release to package. Both values are required; CI resolves them
# from the GitHub release (see .github/workflows/build.yml).
ARG BROWSEROS_VERSION
ARG BROWSEROS_SHA256
ARG BROWSEROS_DEB_URL=https://github.com/browseros-ai/BrowserOS/releases/download/browserclaw/v${BROWSEROS_VERSION}/BrowserOS_neo_v${BROWSEROS_VERSION}_amd64.deb

# Install BrowserOS neo from the official Debian package. add-pkg prepares the
# environment package scripts expect (e.g. /var/log -> /config/log) and cleans
# up afterwards. xdotool is used by the window-guard service to undo the window
# minimize that would otherwise leave the web GUI black and unclickable, and
# obxprop, which the base image ships with Openbox, tells a minimized window
# from one that was never shown.
RUN \
    set -eu; \
    test -n "${BROWSEROS_VERSION}" || { echo "BROWSEROS_VERSION is required" >&2; exit 1; }; \
    test -n "${BROWSEROS_SHA256}" || { echo "BROWSEROS_SHA256 is required" >&2; exit 1; }; \
    add-pkg ca-certificates; \
    add-pkg --virtual build-deps curl; \
    curl -fsSL --retry 3 -o /tmp/browseros-neo.deb "${BROWSEROS_DEB_URL}"; \
    echo "${BROWSEROS_SHA256}  /tmp/browseros-neo.deb" | sha256sum -c -; \
    add-pkg /tmp/browseros-neo.deb fonts-noto-cjk xdotool; \
    del-pkg build-deps; \
    test -x /usr/bin/browserclaw; \
    test -x /opt/base/bin/obxprop; \
    rm -f /tmp/browseros-neo.deb

# Generate and install favicons from the icon shipped in the package.
RUN install_app_icon.sh file:///usr/share/icons/hicolor/256x256/apps/browserclaw.png

# Teach the base image's nginx where to find the MCP configuration that
# 55-mcp.sh generates at container start. The base image has no generic
# include hook, so one include line is added per level; the script fails the
# build when the base image no longer looks the way it expects.
COPY scripts/patch-nginx-includes.sh /tmp/patch-nginx-includes.sh
RUN \
    sh /tmp/patch-nginx-includes.sh && \
    rm -f /tmp/patch-nginx-includes.sh

COPY rootfs/ /

# Docker Desktop on Windows marks every file in the build context as
# executable, while a Linux checkout takes the mode from git. A non-empty
# *.dep file is parsed as a Boolean, but an executable one is run and its
# output is used instead, so an empty executable *.dep file fails to load and
# the service group refuses to start. Normalize the modes of the files this
# image adds instead of trusting the build context: the dependency markers are
# plain files, while the init script and the service programs must be
# executable. The base image's own files are left alone, since some of its
# respawn files are empty Boolean markers that must not become executable.
RUN \
    find /etc/services.d -name '*.dep' -exec chmod 0644 {} + && \
    chmod 0755 \
        /etc/cont-init.d/55-mcp.sh \
        /etc/cont-init.d/56-openbox-keys.sh \
        /etc/services.d/window-guard/run \
        /etc/services.d/window-guard/respawn && \
    set-cont-env APP_NAME "BrowserOS neo" && \
    set-cont-env APP_VERSION "${BROWSEROS_VERSION}" && \
    set-cont-env DOCKER_IMAGE_VERSION "${BROWSEROS_VERSION}"

# Public environment variables.
#
# Both listeners default to the same port: the web GUI serves MCP on /mcp, so
# a container exposes a single port unless MCP_LISTENING_PORT is moved
# elsewhere (see 55-mcp.sh).
ENV \
    KEEP_APP_RUNNING=1 \
    BROWSER_SANDBOX=auto \
    WEB_LISTENING_PORT=9300 \
    MCP_LISTENING_PORT=9300

EXPOSE 9300

LABEL \
    org.opencontainers.image.title="browseros-neo" \
    org.opencontainers.image.description="BrowserOS neo with a web GUI (noVNC) and a token-protected MCP endpoint" \
    org.opencontainers.image.source="https://github.com/tinyrack-net/browseros-neo-docker" \
    org.opencontainers.image.version="${BROWSEROS_VERSION}"
