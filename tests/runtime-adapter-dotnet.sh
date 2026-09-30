#!/usr/bin/env bash
# Unit-test docker/dotnet/entrypoint.sh with a fake `dotnet` on PATH.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="${ROOT}/docker/dotnet/entrypoint.sh"
FAILED=0

if [[ ! -x "${ENTRY}" && ! -f "${ENTRY}" ]]; then
  echo "FAIL: missing ${ENTRY}"
  exit 1
fi
chmod +x "${ENTRY}"

WORKDIR="$(mktemp -d -t asa-adapter.XXXXXX)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

mkdir -p "${WORKDIR}/bin" "${WORKDIR}/app"
# Fake dotnet prints env keys of interest and argv.
cat > "${WORKDIR}/bin/dotnet" <<'EOF'
#!/bin/sh
echo "DOTNET_ARGV=$*"
env | grep -E '^(ASPNETCORE_URLS|HostOptions__ShutdownTimeout|PORT|APP_PROTOCOL)=' | sort
env | grep -E '^Kestrel__' | sort
EOF
chmod +x "${WORKDIR}/bin/dotnet"

# Minimal DLL placeholder the entrypoint requires.
: > "${WORKDIR}/app/App.dll"

run_entry() {
  (
    cd "${WORKDIR}"
    export PATH="${WORKDIR}/bin:/usr/bin:/bin"
    export APP_DLL=App.dll
    # shellcheck disable=SC2030
    "$@"
  )
}

echo "== web: PORT + APP_PROTOCOL=http + SHUTDOWN =="
out="$(
  env -i PATH="${WORKDIR}/bin:/usr/bin:/bin" HOME=/tmp \
    APP_DLL=App.dll APP_HOME="${WORKDIR}/app" \
    PORT=8080 APP_PROTOCOL=http SHUTDOWN_TIMEOUT_SECONDS=25 \
    "${ENTRY}" --mode=api
)" || { echo "FAIL: web entry failed"; echo "${out}"; exit 1; }
printf '%s\n' "${out}" | grep -qx 'ASPNETCORE_URLS=http://+:8080' || { echo "FAIL: ASPNETCORE_URLS"; echo "${out}"; FAILED=1; }
printf '%s\n' "${out}" | grep -q 'Kestrel__' && { echo "FAIL: Kestrel set for http"; echo "${out}"; FAILED=1; }
printf '%s\n' "${out}" | grep -qx 'HostOptions__ShutdownTimeout=0:00:25' || { echo "FAIL: HostOptions"; echo "${out}"; FAILED=1; }
printf '%s\n' "${out}" | grep -qx "DOTNET_ARGV=${WORKDIR}/app/App.dll --mode=api" || { echo "FAIL: argv"; echo "${out}"; FAILED=1; }
echo "OK: web mapping"

echo "== grpc: APP_PROTOCOL=h2c =="
out="$(
  env -i PATH="${WORKDIR}/bin:/usr/bin:/bin" HOME=/tmp \
    APP_DLL=App.dll APP_HOME="${WORKDIR}/app" \
    PORT=8080 APP_PROTOCOL=h2c SHUTDOWN_TIMEOUT_SECONDS=10 \
    "${ENTRY}"
)" || { echo "FAIL: grpc entry failed"; FAILED=1; out=""; }
printf '%s\n' "${out}" | grep -qx 'Kestrel__EndpointDefaults__Protocols=Http2' || { echo "FAIL: Kestrel Http2"; echo "${out}"; FAILED=1; }
printf '%s\n' "${out}" | grep -qx 'HostOptions__ShutdownTimeout=0:00:10' || { echo "FAIL: HostOptions 10s"; echo "${out}"; FAILED=1; }
echo "OK: grpc mapping"

echo "== base-image ASPNETCORE_HTTP_PORTS is cleared; PORT wins =="
out="$(
  env -i PATH="${WORKDIR}/bin:/usr/bin:/bin" HOME=/tmp \
    APP_DLL=App.dll APP_HOME="${WORKDIR}/app" \
    PORT=8080 APP_PROTOCOL=http SHUTDOWN_TIMEOUT_SECONDS=25 \
    ASPNETCORE_HTTP_PORTS=9999 ASPNETCORE_URLS=http://bad \
    "${ENTRY}"
)" || { echo "FAIL: clear+PORT entry"; echo "${out}"; FAILED=1; out=""; }
printf '%s\n' "${out}" | grep -qx 'ASPNETCORE_URLS=http://+:8080' || { echo "FAIL: PORT should win over base image"; echo "${out}"; FAILED=1; }
printf '%s\n' "${out}" | grep -q 'ASPNETCORE_HTTP_PORTS=' && { echo "FAIL: HTTP_PORTS should be unset"; echo "${out}"; FAILED=1; }
echo "OK: base-image listen envs cleared"

echo "== reserved Kestrel__ rejected =="
if env -i PATH="${WORKDIR}/bin:/usr/bin:/bin" HOME=/tmp \
     APP_DLL=App.dll APP_HOME="${WORKDIR}/app" PORT=8080 Kestrel__Endpoints__Http__Url=http://+:1 \
     "${ENTRY}" >/tmp/adapter-err.txt 2>&1; then
  echo "FAIL: expected non-zero with Kestrel__ set"
  FAILED=1
else
  grep -q 'Kestrel__' /tmp/adapter-err.txt \
    && echo "OK: Kestrel__ rejected" \
    || { echo "FAIL: wrong error"; cat /tmp/adapter-err.txt; FAILED=1; }
fi

echo "== worker (no PORT) still runs =="
out="$(
  env -i PATH="${WORKDIR}/bin:/usr/bin:/bin" HOME=/tmp \
    APP_DLL=App.dll APP_HOME="${WORKDIR}/app" SHUTDOWN_TIMEOUT_SECONDS=25 \
    "${ENTRY}" --worker
)" || { echo "FAIL: worker entry"; FAILED=1; out=""; }
printf '%s\n' "${out}" | grep -q 'ASPNETCORE_URLS=' && { echo "FAIL: worker should not set ASPNETCORE_URLS"; FAILED=1; }
printf '%s\n' "${out}" | grep -qx "DOTNET_ARGV=${WORKDIR}/app/App.dll --worker" || { echo "FAIL: worker argv"; echo "${out}"; FAILED=1; }
echo "OK: worker without PORT"

if [[ "${FAILED}" -ne 0 ]]; then
  echo "runtime-adapter-dotnet FAILED"
  exit 1
fi
echo "runtime-adapter-dotnet ok"
