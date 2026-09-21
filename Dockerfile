# ── Build stage ───────────────────────────────────────────────────
# Elixir 1.19 / OTP 28, matching mix.exs (elixir: "~> 1.19") and the CI
# workflow's erlef/setup-beam versions. Pinned by digest, resolved from
# hexpm/elixir:1.19.6-erlang-28.5.0.6-debian-bookworm-20260918-slim.
FROM hexpm/elixir:1.19.6-erlang-28.5.0.6-debian-bookworm-20260918-slim@sha256:8713308eb471a5f84aa55a22cf265d5f652629de747af83b22cc27706fe0c8f6 AS build

WORKDIR /app

# Install build deps
RUN apt-get update -y && \
    apt-get install -y build-essential git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
RUN mix release

# ── Runtime stage ─────────────────────────────────────────────────
# Same debian distro (bookworm) as the build stage's base image.
# Pinned by digest, resolved from debian:bookworm-20260918-slim.
#
# No HEALTHCHECK: this is a debian-slim image with no curl/wget
# installed, and adding one only for a healthcheck would grow the
# runtime image and its attack surface. Add curl (or a lightweight
# Elixir-based check via the release's remote console) if a
# HEALTHCHECK becomes required.
FROM debian:bookworm-20260918-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS runtime

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Run as non-root user. Ownership of /app itself is fixed up here (mirroring
# phx.gen.release's generated Dockerfile) so the app user can create new
# entries in its own working directory at runtime (e.g. the release's tmp/
# dir, created on boot), without needing to own the release files below.
RUN useradd --create-home app && chown app:app /app
USER app

# No --chown here: the release files land root-owned (COPY ignores USER and
# defaults to UID/GID 0 without --chown), so the app user can read and
# execute them but not modify or replace them at runtime. The app user can
# still create new files under /app (the release's tmp/ dir on boot,
# RELEASE_ROOT-relative by default) because /app itself is chown'd to app
# above; directory write permission, not per-file ownership, governs that.
COPY --from=build /app/_build/prod/rel/demo ./

ENV PHX_SERVER=true

EXPOSE 4000

CMD ["/app/bin/demo", "start"]
