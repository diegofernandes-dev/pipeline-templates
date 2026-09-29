# Platform runtime image for .NET web/API apps.
# Build context = CI publish output (not the application repository).
# Pipeline sets RUNTIME_IMAGE from the project TFM and APP_DLL from the csproj name.
ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/aspnet:8.0
FROM ${RUNTIME_IMAGE}

ARG APP_DLL

# The charts pin podSecurityContext.runAsUser/runAsGroup/fsGroup to this UID. If a future
# base image changes APP_UID, fail here at build time instead of at runtime with a
# permission error on /app.
ARG EXPECTED_APP_UID=1654

WORKDIR /app

COPY . .

RUN test -n "${APP_DLL}" \
  && test -f "/app/${APP_DLL}" \
  && test -n "${APP_UID}" \
  && { [ "${APP_UID}" = "${EXPECTED_APP_UID}" ] \
       || { echo "APP_UID=${APP_UID} does not match chart podSecurityContext runAsUser=${EXPECTED_APP_UID}; update charts/*/values.yaml together with this Dockerfile" >&2; exit 1; }; } \
  && printf '#!/bin/sh\nexec dotnet /app/%s "$@"\n' "${APP_DLL}" > /app/start.sh \
  && chmod +x /app/start.sh \
  && chown -R "${APP_UID}:${APP_UID}" /app

ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080

USER $APP_UID
ENTRYPOINT ["/app/start.sh"]
