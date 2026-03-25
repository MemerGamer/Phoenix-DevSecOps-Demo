# ── Build stage ───────────────────────────────────────────────────
FROM hexpm/elixir:1.17.3-erlang-27.1-debian-bookworm-20240904-slim AS build

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
COPY assets assets

RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ── Runtime stage ─────────────────────────────────────────────────
FROM debian:bookworm-20240904-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Run as non-root user
RUN useradd --create-home app
USER app

COPY --from=build --chown=app:app /app/_build/prod/rel/demo ./

ENV PHX_SERVER=true

EXPOSE 4000

CMD ["/app/bin/demo", "start"]
