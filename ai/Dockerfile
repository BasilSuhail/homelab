# llama.cpp's server, built for the PC's GTX 1050 Ti. Built on the board by
# deploy/install-ai.sh.
#
# Built here rather than pulled, because every prebuilt image is wrong for this
# card one way or another: the official Linux CUDA builds use CUDA 12.8 or 13,
# and 12.8 needs NVIDIA driver 570 (homelab runs Debian's 550) while 13 dropped
# Pascal (compute 6.1) altogether. CUDA 12.4 is the newest that driver 550
# runs. Only sm_61 is compiled, which also keeps the build to minutes.
#
# No web UI and no HTTPS client: the server is reached from inside the cluster
# only, and the model file is downloaded by the installer.
ARG CUDA_VERSION=12.4.1

FROM docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu22.04 AS build
# A release about two weeks old when chosen. CUDA 13-only releases will end
# Pascal support, so this moves only on purpose.
ARG LLAMA_TAG=b11361
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git cmake build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${LLAMA_TAG}" https://github.com/ggml-org/llama.cpp /src
WORKDIR /src
# -j4: nvcc takes a GB or two per job, and the PC's apps keep running while
# this builds. The CUDA driver library is only a stub at build time, hence
# --allow-shlib-undefined; the real one comes from the host at run time.
RUN cmake -B build \
        -DGGML_CUDA=ON -DGGML_NATIVE=OFF -DCMAKE_CUDA_ARCHITECTURES=61 \
        -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_OPENSSL=OFF \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined \
    && cmake --build build --config Release -j4 --target llama-server

FROM docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu22.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/bin/llama-server /usr/local/bin/llama-server
ENTRYPOINT ["/usr/local/bin/llama-server"]
