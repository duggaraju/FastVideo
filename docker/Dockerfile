FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build
ARG PROJECT
WORKDIR /source
COPY . .
RUN dotnet restore "src/${PROJECT}/${PROJECT}.csproj" \
    && dotnet publish "src/${PROJECT}/${PROJECT}.csproj" --no-restore -c Release -o /app

FROM mcr.microsoft.com/dotnet/runtime:10.0-noble
ARG APP_DLL
ENV APP_DLL=${APP_DLL} \
    DOTNET_EnableDiagnostics=0
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
USER app
ENTRYPOINT ["sh", "-c", "exec dotnet \"$APP_DLL\""]