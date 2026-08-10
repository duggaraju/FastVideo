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
    && tar --extract --xz --file ffmpeg.tar.xz --directory /opt/ffmpeg --strip-components=1 \
    && install --directory /opt/ffmpeg/share/vmaf \
    && curl --fail --location --silent --show-error \
        "https://raw.githubusercontent.com/Netflix/vmaf/v${VMAF_VERSION}/model/vmaf_v0.6.1.json" \
        --output /opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json

FROM mcr.microsoft.com/azurelinux/base/core:3.0 AS ffmpeg-custom
ARG FFMPEG_VERSION=9.0
ARG DAV1D_VERSION=1.5.4
ARG SVT_AV1_VERSION=4.0.1
ARG VMAF_VERSION=3.0.0
ARG X264_REF=stable
RUN tdnf install --assumeyes \
    autoconf automake binutils ca-certificates cmake curl gawk gcc gcc-c++ glibc-devel \
    kernel-headers libtool make meson nasm ninja-build pkg-config python3 tar xz \
    && tdnf clean all
WORKDIR /build
RUN curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
        "https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.gz" \
        --output dav1d.tar.gz \
    && mkdir dav1d \
    && tar --extract --gzip --file dav1d.tar.gz --directory dav1d --strip-components=1 \
    && meson setup dav1d/build dav1d \
        --buildtype=release \
        --default-library=shared \
        --prefix=/opt/ffmpeg \
        --libdir=lib \
        -Denable_tools=false \
        -Denable_tests=false \
    && meson compile -C dav1d/build \
    && meson install -C dav1d/build
RUN curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
        "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${SVT_AV1_VERSION}/SVT-AV1-v${SVT_AV1_VERSION}.tar.gz" \
        --output svt-av1.tar.gz \
    && mkdir svt-av1 \
    && tar --extract --gzip --file svt-av1.tar.gz --directory svt-av1 --strip-components=1 \
    && cmake -S svt-av1 -B svt-av1/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/ffmpeg \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_APPS=OFF \
        -DBUILD_DEC=ON \
        -DBUILD_SHARED_LIBS=ON \
    && cmake --build svt-av1/build --parallel "$(nproc)" \
    && cmake --install svt-av1/build
RUN curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
        "https://github.com/Netflix/vmaf/archive/refs/tags/v${VMAF_VERSION}.tar.gz" \
        --output vmaf.tar.gz \
    && mkdir vmaf \
    && tar --extract --gzip --file vmaf.tar.gz --directory vmaf --strip-components=1 \
    && meson setup vmaf/libvmaf/build vmaf/libvmaf \
        --buildtype=release \
        --default-library=shared \
        --prefix=/opt/ffmpeg \
        --libdir=lib \
    && meson compile -C vmaf/libvmaf/build \
    && meson install -C vmaf/libvmaf/build
RUN curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
        "https://code.videolan.org/videolan/x264/-/archive/${X264_REF}/x264-${X264_REF}.tar.gz" \
        --output x264.tar.gz \
    && mkdir x264 \
    && tar --extract --gzip --file x264.tar.gz --directory x264 --strip-components=1 \
    && cd x264 \
    && ./configure \
        --prefix=/opt/ffmpeg \
        --enable-shared \
        --enable-pic \
        --disable-cli \
    && make --jobs "$(nproc)" \
    && make install
RUN curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
        "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz" \
        --output ffmpeg.tar.gz \
    && mkdir ffmpeg \
    && tar --extract --gzip --file ffmpeg.tar.gz --directory ffmpeg --strip-components=1 \
    && cd ffmpeg \
    && PKG_CONFIG_PATH=/opt/ffmpeg/lib/pkgconfig ./configure \
        --prefix=/opt/ffmpeg \
        --enable-gpl \
        --enable-libdav1d \
        --enable-libsvtav1 \
        --enable-libvmaf \
        --enable-libx264 \
        --enable-shared \
        --disable-static \
        --disable-avdevice \
        --disable-debug \
        --disable-doc \
        --disable-ffplay \
        --extra-cflags=-I/opt/ffmpeg/include \
        --extra-ldflags=-L/opt/ffmpeg/lib \
    && make --jobs "$(nproc)" \
    && make install \
    && install --directory /opt/ffmpeg/share/vmaf \
    && cp /build/vmaf/model/vmaf_v0.6.1.json /opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json

FROM ffmpeg-${FFMPEG_BUILD} AS ffmpeg

FROM mcr.microsoft.com/dotnet/sdk:10.0-resolute AS build
ARG PROJECT
WORKDIR /source
COPY . .
RUN dotnet restore "src/${PROJECT}/${PROJECT}.csproj" \
    && dotnet publish "src/${PROJECT}/${PROJECT}.csproj" --no-restore -c Release -o /app

FROM mcr.microsoft.com/dotnet/runtime:10.0-azurelinux3.0 AS runtime
COPY --from=ffmpeg /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe /opt/ffmpeg/bin/
COPY --from=ffmpeg /opt/ffmpeg/lib /opt/ffmpeg/lib
COPY --from=ffmpeg /opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json /opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json
ENV PATH="/opt/ffmpeg/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/ffmpeg/lib"

FROM runtime AS final
ARG APP_DLL
ENV APP_DLL=${APP_DLL} \
    DOTNET_EnableDiagnostics=0
WORKDIR /app
COPY --from=build /app .
USER app
ENTRYPOINT ["sh", "-c", "exec dotnet \"$APP_DLL\""]