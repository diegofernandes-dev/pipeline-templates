#!/bin/sh
# Platform runtime adapter for .NET.
# Translates the chart's runtime-agnostic contract into .NET host configuration, then
# execs the published DLL as PID 1 so SIGTERM reaches the app.
#
# Contract (set by the chart):
#   PORT                      listen port (web/grpc)
#   APP_PROTOCOL              http | h2c (web/grpc)
#   SHUTDOWN_TIMEOUT_SECONDS  HostOptions.ShutdownTimeout budget
#   CPU_REQUEST_MILLICORES    exposed for future use; not consumed here
#
# APP_DLL is baked into the image as an ENV at build time.
set -eu

# mcr.microsoft.com/dotnet/aspnet sets ASPNETCORE_HTTP_PORTS (and sometimes URLS).
# Those collide with PORT from the chart — clear them so the contract wins.
# Manifesto config that sets ASPNETCORE_* / Kestrel__* is rejected earlier by
# DeployContract (platform/runtimes/dotnet.yml reservedConfig).
unset ASPNETCORE_URLS ASPNETCORE_HTTP_PORTS ASPNETCORE_HTTPS_PORTS || true

# Kestrel__* is never set by the base image — only by a misconfigured manifesto envFrom.
if env | grep -q '^Kestrel__'; then
  echo "platform: Kestrel__* is reserved for the .NET runtime adapter — remove it from manifesto config" >&2
  exit 1
fi

if [ -n "${PORT:-}" ]; then
  export ASPNETCORE_URLS="http://+:${PORT}"
fi

if [ "${APP_PROTOCOL:-}" = "h2c" ]; then
  export Kestrel__EndpointDefaults__Protocols=Http2
elif [ -n "${APP_PROTOCOL:-}" ] && [ "${APP_PROTOCOL}" != "http" ]; then
  echo "platform: unsupported APP_PROTOCOL='${APP_PROTOCOL}' (expected http or h2c)" >&2
  exit 1
fi

if [ -n "${SHUTDOWN_TIMEOUT_SECONDS:-}" ]; then
  case "${SHUTDOWN_TIMEOUT_SECONDS}" in
    ''|*[!0-9]*)
      echo "platform: SHUTDOWN_TIMEOUT_SECONDS must be a positive integer (got '${SHUTDOWN_TIMEOUT_SECONDS}')" >&2
      exit 1
      ;;
  esac
  if [ "${SHUTDOWN_TIMEOUT_SECONDS}" -le 0 ]; then
    echo "platform: SHUTDOWN_TIMEOUT_SECONDS must be > 0" >&2
    exit 1
  fi
  # HostOptions.ShutdownTimeout is a TimeSpan — emit H:MM:SS.
  _h=$((SHUTDOWN_TIMEOUT_SECONDS / 3600))
  _m=$(((SHUTDOWN_TIMEOUT_SECONDS % 3600) / 60))
  _s=$((SHUTDOWN_TIMEOUT_SECONDS % 60))
  HostOptions__ShutdownTimeout="$(printf '%d:%02d:%02d' "${_h}" "${_m}" "${_s}")"
  export HostOptions__ShutdownTimeout
fi

if [ -z "${APP_DLL:-}" ]; then
  echo "platform: APP_DLL is required (set at image build time)" >&2
  exit 1
fi

APP_HOME="${APP_HOME:-/app}"
if [ ! -f "${APP_HOME}/${APP_DLL}" ]; then
  echo "platform: ${APP_HOME}/${APP_DLL} not found" >&2
  exit 1
fi

exec dotnet "${APP_HOME}/${APP_DLL}" "$@"
