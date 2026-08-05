ARG FFMPEG_BUILD=btbn

FROM ubuntu:26.04 AS ffmpeg-btbn
ARG FFMPEG_ARCHIVE=ffmpeg-master-latest-linux64-gpl-shared.tar.xz
ARG VMAF_VERSION=3.0.0
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl --fail --location --silent --show-error \
        "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/${FFMPEG_ARCHIVE}" \
        --output ffmpeg.tar.xz \
    && curl --fail --location --silent --show-error \
        "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/checksums.sha256" \
        --output checksums.sha256 \
    && grep "  ${FFMPEG_ARCHIVE}$" checksums.sha256 > ffmpeg.sha256 \
    && sed --in-place "s#  ${FFMPEG_ARCHIVE}\$#  ffmpeg.tar.xz#" ffmpeg.sha256 \
    && sha256sum --check ffmpeg.sha256 \
    && install --directory /opt/ffmpeg \
    && tar --extract --xz --file ffmpeg.tar.xz --directory /opt/ffmpeg --strip-components=1
RUN install --directory /opt/ffmpeg/share/vmaf \
    && curl --fail --location --silent --show-error \
        "https://raw.githubusercontent.com/Netflix/vmaf/v${VMAF_VERSION}/model/vmaf_v0.6.1.json" \
        --output /opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json

FROM ubuntu:26.04 AS ffmpeg-ubuntu
RUN mkdir --parents /opt/ffmpeg

FROM ffmpeg-${FFMPEG_BUILD} AS ffmpeg

FROM mcr.microsoft.com/dotnet/sdk:10.0-resolute AS build
ARG PROJECT
WORKDIR /source
COPY . .
RUN dotnet restore "src/${PROJECT}/${PROJECT}.csproj" \
    && dotnet publish "src/${PROJECT}/${PROJECT}.csproj" --no-restore -c Release -o /app

FROM mcr.microsoft.com/dotnet/runtime:10.0-resolute AS runtime-btbn
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=ffmpeg /opt/ffmpeg /opt/ffmpeg
ENV PATH="/opt/ffmpeg/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/ffmpeg/lib"

FROM mcr.microsoft.com/dotnet/runtime:10.0-resolute AS runtime-ubuntu
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*

FROM runtime-${FFMPEG_BUILD} AS final
ARG APP_DLL
ENV APP_DLL=${APP_DLL} \
    DOTNET_EnableDiagnostics=0
WORKDIR /app
COPY --from=build /app .
USER app
ENTRYPOINT ["sh", "-c", "exec dotnet \"$APP_DLL\""]