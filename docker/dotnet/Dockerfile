# Platform runtime image for .NET apps (Application + ScheduledJob).
# Build context = CI publish output (not the application repository).
# Pipeline copies entrypoint.sh into the context and sets RUNTIME_IMAGE / APP_DLL.
ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/aspnet:8.0
FROM ${RUNTIME_IMAGE}

ARG APP_DLL
# Platform UID — charts pin podSecurityContext.runAsUser/runAsGroup/fsGroup to this value.
# If a future base image changes APP_UID, fail here at build time.
ARG PLATFORM_UID=1654

WORKDIR /app

COPY . .

RUN test -n "${APP_DLL}" \
  && test -f "/app/${APP_DLL}" \
  && test -f /app/entrypoint.sh \
  && test -n "${APP_UID}" \
  && { [ "${APP_UID}" = "${PLATFORM_UID}" ] \
       || { echo "APP_UID=${APP_UID} does not match platform UID ${PLATFORM_UID}; update charts/*/values.yaml together with this Dockerfile" >&2; exit 1; }; } \
  && chmod +x /app/entrypoint.sh \
  && chown -R "${APP_UID}:${APP_UID}" /app

ENV APP_DLL=${APP_DLL}
EXPOSE 8080

USER $APP_UID
ENTRYPOINT ["/app/entrypoint.sh"]
