# syntax=docker/dockerfile:1.7

# Python 3.11 is a hard ceiling, not a preference: PrusaLink pins
# pydantic==1.10.12, whose newest published wheel is cp311. On 3.12+ pip falls
# back to a source build that fails.
#
# The digest is what makes a rebuild years from now produce today's image. Bump
# BASE_DIGEST deliberately; never rely on the floating tag.
ARG BASE_IMAGE=python:3.11-slim-bookworm
ARG BASE_DIGEST=sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84


# ---------------------------------------------------------------------------
# builder — compiles the two dependencies that ship no wheels
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS builder

# python-prctl has no wheels at all and needs libcap headers; zeroconf builds
# Cython internals. Everything else in the dependency tree is pure Python or a
# prebuilt wheel. git is needed because PRUSALINK_SPEC is a git+https URL.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        libcap-dev \
    && rm -rf /var/lib/apt/lists/*

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# A complete pip requirement, always pinned to a 40-character commit SHA so
# release and nightly builds share one code path:
#   prusalink @ git+https://github.com/prusa3d/Prusa-Link.git@<sha>
#
# Git rather than PyPI because PyPI lags GitHub tags — 0.8.2 exists in master
# but was never published — which would race the release watcher. A SHA is
# content-addressed, so this is exactly as reproducible as a version pin.
ARG PRUSALINK_SPEC

# Build tooling is pinned as tightly as the application. Pinning PrusaLink to a
# SHA but letting `pip install --upgrade setuptools` float is not a reproducible
# build -- and it is not hypothetical: setuptools 82.0.0 removed pkg_resources,
# which PrusaLink imports unguarded at web/main.py:15. The reflexive
# `--upgrade pip setuptools wheel` idiom produces an image that dies on the
# first request. 80.9.0 is the last release before the deprecation warnings.
#
# pip itself is a declared runtime dependency of PrusaLink (pip>=22.2.0 in
# requirements.txt), so it stays in the venv deliberately. wheel does not --
# pip provisions it into an isolated build environment as needed.
ARG PIP_VERSION=26.2.1
ARG SETUPTOOLS_VERSION=80.9.0

RUN test -n "${PRUSALINK_SPEC}" \
        || { echo "ERROR: PRUSALINK_SPEC build arg is required" >&2; exit 1; } \
    && pip install --upgrade "pip==${PIP_VERSION}" \
    && pip install "setuptools==${SETUPTOOLS_VERSION}" \
    && pip install "${PRUSALINK_SPEC}" \
    && find /opt/venv -name '__pycache__' -type d -prune -exec rm -rf {} +


# ---------------------------------------------------------------------------
# runtime — carries no compiler
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS runtime

# Only the shared objects the installed wheels dlopen at runtime, plus tini
# (reaps zombies from the Popen restart path in daemon.py) and gosu (drops
# privileges without the signal-forwarding problems of su).
RUN apt-get update && apt-get install -y --no-install-recommends \
        gosu \
        libcap2 \
        libmagic1 \
        libturbojpeg0 \
        libudev1 \
        tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    # PrusaLink imports pkg_resources at web/main.py:15, which warns on every
    # start under any modern setuptools. The constraint is real and is pinned
    # deliberately in the builder stage, so the warning tells the operator
    # nothing actionable -- it just trains them to ignore startup output on a
    # machine that controls a heater. Matched on the message text so genuine
    # warnings still surface.
    PYTHONWARNINGS="ignore:pkg_resources is deprecated as an API:UserWarning"

# Smoke test the shipped artifact, not the builder. Importing prusa.link pulls
# in the entire module graph, and several modules touch native libraries at
# import time rather than lazily -- cameras/encoders.py:20 constructs
# TurboJPEG() at module scope, which searches for libturbojpeg.so and raises if
# it is absent. A missing entry in the apt list above is therefore not a
# degraded feature but a daemon that cannot start, so this turns the runtime
# dependency list from an assumption into an assertion. It also catches build
# tooling drift, such as a setuptools that no longer ships pkg_resources.
RUN prusalink --version && python -c "import prusa.link.__main__"

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY healthcheck.py /usr/local/bin/prusalink-healthcheck
COPY prusalink.ini.template /usr/local/share/prusalink/prusalink.ini.template
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/prusalink-healthcheck \
    && mkdir -p /data /etc/prusalink

# config.py resolves pid_file, power_panic, threshold.data,
# prusa_printer_settings.ini and "PrusaLink gcodes" all relative to data_dir,
# so /data is the entirety of PrusaLink's mutable state.
VOLUME ["/data", "/etc/prusalink"]

EXPOSE 8080

# PrusaLink only handles SIGTERM on the daemonizing path (__main__.py:245 wires
# it inside DaemonContext). The foreground path a container uses catches
# KeyboardInterrupt — SIGINT — and nothing else, so a plain `docker stop` kills
# it before prusa_link.stop() and http.stop() can run. Asking Docker for SIGINT
# is the whole fix.
#
# Necessary but not sufficient: the resulting shutdown takes up to ~17s,
# because prusa_link.stop() enqueues an M117 to the printer's LCD and waits out
# STATE_CHANGE_TIMEOUT (const.py:86) when nothing answers. Docker's default
# grace period is 10s, so callers must raise it or they will SIGKILL a healthy
# shutdown in progress. compose.yaml sets stop_grace_period: 30s; plain
# `docker run` users want `docker stop --time 30`.
STOPSIGNAL SIGINT

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD ["/usr/local/bin/prusalink-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["prusalink", "-f", "-c", "/etc/prusalink/prusalink.ini"]

ARG PRUSALINK_SPEC
ARG PRUSALINK_VERSION=dev
ARG PRUSALINK_REVISION
LABEL org.opencontainers.image.title="PrusaLink" \
      org.opencontainers.image.description="PrusaLink in a reproducible container" \
      org.opencontainers.image.source="https://github.com/brysonreece/prusa-link-docker" \
      org.opencontainers.image.url="https://github.com/prusa3d/Prusa-Link" \
      org.opencontainers.image.licenses="Freeware" \
      org.opencontainers.image.version="${PRUSALINK_VERSION}" \
      org.opencontainers.image.revision="${PRUSALINK_REVISION}"
