# Platform Dockerfile for .NET web/API apps.
# Build context = application repository root.
# Required build-arg: PROJECT (path to .csproj, e.g. src/Sample.Api/Sample.Api.csproj)
ARG SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:8.0
ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/aspnet:8.0

FROM ${SDK_IMAGE} AS build
ARG PROJECT
WORKDIR /src

COPY . .
RUN test -n "${PROJECT}" && test -f "${PROJECT}"
RUN dotnet restore "${PROJECT}"
RUN dotnet publish "${PROJECT}" -c Release -o /app/publish --no-restore

FROM ${RUNTIME_IMAGE} AS final
ARG PROJECT
WORKDIR /app

COPY --from=build /app/publish .

RUN APP_DLL="$(basename "${PROJECT}" .csproj).dll" \
  && test -f "/app/${APP_DLL}" \
  && printf '#!/bin/sh\nexec dotnet /app/%s "$@"\n' "${APP_DLL}" > /app/start.sh \
  && chmod +x /app/start.sh \
  && chown -R "${APP_UID}:${APP_UID}" /app

ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080

USER $APP_UID
ENTRYPOINT ["/app/start.sh"]
