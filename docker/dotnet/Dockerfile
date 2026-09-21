# Platform runtime image for .NET web/API apps.
# Build context = CI publish output (not the application repository).
# Pipeline sets RUNTIME_IMAGE from the project TFM and APP_DLL from the csproj name.
ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/aspnet:8.0
FROM ${RUNTIME_IMAGE}

ARG APP_DLL
WORKDIR /app

COPY . .

RUN test -n "${APP_DLL}" \
  && test -f "/app/${APP_DLL}" \
  && printf '#!/bin/sh\nexec dotnet /app/%s "$@"\n' "${APP_DLL}" > /app/start.sh \
  && chmod +x /app/start.sh \
  && chown -R "${APP_UID}:${APP_UID}" /app

ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080

USER $APP_UID
ENTRYPOINT ["/app/start.sh"]
