ARG FFMPEG_BUILD=btbn
ARG FFMPEG_IMAGE=ffmpeg-build

FROM mcr.microsoft.com/azurelinux/base/core:3.0 AS ffmpeg-btbn
ARG TARGETARCH
ARG FFMPEG_ARCHIVE
ARG VMAF_VERSION=3.0.0
RUN tdnf install --assumeyes ca-certificates curl tar xz \
    && tdnf clean all
WORKDIR /build
RUN if [ -z "${FFMPEG_ARCHIVE}" ]; then \
        case "${TARGETARCH}" in \
            amd64) FFMPEG_ARCHIVE=ffmpeg-master-latest-linux64-gpl-shared.tar.xz ;; \
            arm64) FFMPEG_ARCHIVE=ffmpeg-master-latest-linuxarm64-gpl-shared.tar.xz ;; \
            *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
        esac; \
    fi \
    && curl --fail --location --silent --show-error \
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
ARG TARGETARCH
ARG FFMPEG_VERSION=9.0
ARG DAV1D_VERSION=1.5.4
ARG SVT_AV1_VERSION=4.0.1
ARG VMAF_VERSION=3.0.0
ARG X264_REF=stable
RUN build_packages="autoconf automake binutils ca-certificates cmake curl gawk gcc gcc-c++ glibc-devel \
        kernel-headers libtool make meson ninja-build pkg-config python3 tar xz" \
    && if [ "${TARGETARCH}" = "amd64" ]; then build_packages="${build_packages} nasm"; fi \
    && tdnf install --assumeyes ${build_packages} \
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

FROM ffmpeg-${FFMPEG_BUILD} AS ffmpeg-build

FROM ${FFMPEG_IMAGE} AS ffmpeg

FROM --platform=$BUILDPLATFORM rust:1.97.0-bookworm AS build
ARG PACKAGE
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        clang g++-aarch64-linux-gnu gcc-aarch64-linux-gnu libc6-dev-arm64-cross pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /source
COPY rust/Cargo.toml rust/Cargo.lock ./
COPY rust/analyzer/Cargo.toml analyzer/Cargo.toml
COPY rust/audio-encoder/Cargo.toml audio-encoder/Cargo.toml
COPY rust/completion/Cargo.toml completion/Cargo.toml
COPY rust/encoder/Cargo.toml encoder/Cargo.toml
COPY rust/stitcher/Cargo.toml stitcher/Cargo.toml
COPY rust/video-core/Cargo.toml video-core/Cargo.toml
RUN mkdir -p analyzer/src audio-encoder/src completion/src encoder/src stitcher/src video-core/src \
    && printf '' > video-core/src/lib.rs \
    && printf 'fn main() {}\n' > analyzer/src/main.rs \
    && printf 'fn main() {}\n' > audio-encoder/src/main.rs \
    && printf 'fn main() {}\n' > completion/src/main.rs \
    && printf 'fn main() {}\n' > encoder/src/main.rs \
    && printf 'fn main() {}\n' > stitcher/src/main.rs \
    && cargo check --locked --package "${PACKAGE}" \
    && rm -rf analyzer/src audio-encoder/src completion/src encoder/src stitcher/src video-core/src
COPY rust/ .
RUN cargo test --locked --package "${PACKAGE}"
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        amd64) rust_target=x86_64-unknown-linux-gnu; strip_command=strip ;; \
        arm64) rust_target=aarch64-unknown-linux-gnu; strip_command=aarch64-linux-gnu-strip ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && rustup target add "${rust_target}" \
    && CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
        CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
        CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++ \
        cargo build --locked --release --package "${PACKAGE}" --target "${rust_target}" \
    && install --directory /app \
    && "${strip_command}" "target/${rust_target}/release/${PACKAGE}" \
    && cp "target/${rust_target}/release/${PACKAGE}" "/app/${PACKAGE}"

FROM mcr.microsoft.com/azurelinux/base/core:3.0 AS final
ARG PACKAGE
RUN tdnf install --assumeyes ca-certificates shadow-utils \
    && tdnf clean all \
    && groupadd --system --gid 1654 app \
    && useradd --system --uid 1654 --gid app --home-dir /app app
COPY --from=ffmpeg /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe /opt/ffmpeg/bin/
COPY --from=ffmpeg /opt/ffmpeg/lib /opt/ffmpeg/lib
COPY --from=ffmpeg /opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json /opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json
COPY --from=build /app/${PACKAGE} /app/video
ENV PATH="/opt/ffmpeg/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/ffmpeg/lib" \
    RUST_LOG=video=info
WORKDIR /app
USER app
ENTRYPOINT ["/app/video"]
