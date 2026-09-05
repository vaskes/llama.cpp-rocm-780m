# Production llama.cpp image for gfx1103 (Radeon 780M) + Zen 4 (Ryzen 7 8700G)
# Built on Ubuntu 24.04's ROCm 7.2.4 packages — portable, no wheel
# re-layout, no host dependency.
#
# Why not TheRock 7.13 wheels? The TheRock gfx110X-all wheels
# (rocm-sdk-core/libraries/devel) are designed for Python use; their
# tarball layout assumes an /opt/rocm-style install and their devel
# symlinks point one level too deep for the pip wheel layout. The
# project shipped by upstream ROCm 7.2.4 (apt: rocm-hip-sdk) is the
# cleanest portable toolchain for C++ projects on Zen 4 / RDNA3.
#
# Verified: --offload-arch=gfx1103 native, no HSA_OVERRIDE_GFX_VERSION.

FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive

# Add AMD's ROCm apt repository (Ubuntu's rocm packages are 7.2.4 stable
# but adding AMD's repo gives us the full SDK with hipBLAS/hipBLASLt/
# rocBLAS dev packages).
RUN apt-get update && apt-get install -y --no-install-recommends curl gnupg ca-certificates \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.4 noble main" > /etc/apt/sources.list.d/rocm.list

# System + build deps + ROCm toolchain. rocm-hip-sdk is a metapackage
# that pulls in hipcc, hip-runtime-amd, llvm/clang, hipBLAS/hipBLASLt/
# rocBLAS, hipFFT, hipRAND, RCCL, etc. ~400MB download.
# Ubuntu 24.04 ships older hipcc 5.7.1, rocm-cmake 6.0.0, rocminfo 5.7.1
# that conflict with AMD's 7.2.4 SDK. Use apt pinning to prefer AMD's
# versions, AND install the AMD-specific versions of all the metapackage
# dependencies first so apt sees them as already-installed.
RUN cat > /etc/apt/preferences.d/rocm-pin << 'EOF'
Package: *
Pin: origin "repo.radeon.com"
Pin-Priority: 1001
EOF
# Install the explicit AMD versions of the conflicting packages
# first to lock them in
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3-pip ca-certificates curl \
        hipcc rocm-cmake rocm-utils rocminfo rocm-core rocm-device-libs \
    && apt-get install -y --no-install-recommends \
        rocm-hip-sdk rocm-dev \
        libgfortran5 libatomic1 libquadmath0 libssl3 \
        cmake ninja-build git pkg-config g++ gcc \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ROCm toolchain env
ENV ROCM_PATH=/opt/rocm
ENV HIP_PATH=/opt/rocm
ENV PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/rocm/lib:/usr/lib/llvm-19/lib:$LD_LIBRARY_PATH

# Verify the toolchain
RUN /opt/rocm/bin/hipcc --version | head -1 \
    && /opt/rocm/bin/hipconfig --version \
    && /opt/rocm/bin/rocminfo | head -5 || true

# Zen 4 / znver4 CPU flags. -march=znver4 enables AVX, AVX2, FMA, F16C,
# BMI1, BMI2, AVX-512 F/DQ/BW/CD/VL, AVX-512 IFMA, VBMI, VBMI2, VNNI,
# BITALG, VPOPCNTDQ, BF16, plus Zen4-specific.
ENV CFLAGS="-O3 -DNDEBUG -march=znver4 -mtune=znver4 -fopenmp -fstack-protector-strong"
ENV CXXFLAGS="-O3 -DNDEBUG -march=znver4 -mtune=znver4 -fopenmp -fstack-protector-strong"
ENV LDFLAGS="-fopenmp"

WORKDIR /opt/build

# llama.cpp
ARG LLAMA_CPP_REF=master
RUN git clone --depth 1 --branch ${LLAMA_CPP_REF} \
        https://github.com/ggml-org/llama.cpp.git /opt/llama.cpp
WORKDIR /opt/llama.cpp

RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=gcc \
        -DCMAKE_CXX_COMPILER=g++ \
        -DCMAKE_HIP_COMPILER=/opt/rocm/llvm/bin/clang++ \
        -DCMAKE_PREFIX_PATH=/opt/rocm \
        -DGGML_HIP=ON \
        -DGGML_CUDA=OFF \
        -DGGML_VULKAN=OFF \
        -DGGML_OPENMP=ON \
        -DGGML_NATIVE=OFF \
        -DGGML_CPU_ALL_VARIANTS=OFF \
        -DGGML_AVX=ON \
        -DGGML_AVX2=ON \
        -DGGML_FMA=ON \
        -DGGML_F16C=ON \
        -DGGML_BMI2=ON \
        -DGGML_AVX512=ON \
        -DGGML_AVX512_VBMI=ON \
        -DGGML_AVX512_VNNI=ON \
        -DGGML_AVX512_BF16=ON \
        -DAMDGPU_TARGETS="gfx1103" \
    && cmake --build build --config Release -j$(nproc) \
    && /opt/llama.cpp/build/bin/llama-server --version \
    && /opt/llama.cpp/build/bin/llama-cli --version \
    && ls -la build/bin/

# ---- Stage 2: runtime -------------------------------------------------------
# Runtime is just the build stage minus build-time deps. We keep
# /opt/rocm intact for runtime (so the binary finds libamdhip64.so etc).
# We also keep /opt/llama.cpp/build for the compiled binaries.
#
# We avoid rocm-hip-runtime (the metapackage) because it pins rocminfo to
# 1.0.0 which conflicts with Ubuntu 24.04's older rocminfo; we install
# the explicit runtime libs we need instead.

FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# Add AMD ROCm repo for runtime libs
RUN apt-get update && apt-get install -y --no-install-recommends curl gnupg ca-certificates \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.4 noble main" > /etc/apt/sources.list.d/rocm.list

# Runtime libs: ROCm runtime + ROCBLAS/hipBLAS/hipBLASLt + the loader.
# We use the explicit packages, not the metapackage, to avoid the
# rocminfo version conflict with Ubuntu 24.04.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3-pip ca-certificates curl \
        hsa-rocr hsa-amd-aqlprofile comgr hip-runtime-amd rocm-smi-lib \
        rocblas hipblas hipblaslt \
        libgfortran5 libgomp1 libomp5-19 libatomic1 libquadmath0 libssl3 libstdc++6 libgcc-s1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/lib/llvm-19/lib/libomp.so.5 /usr/lib/x86_64-linux-gnu/libomp.so \
    # gfx1103 (Radeon 780M) was released after ROCm 7.2 TensileLibrary was built,
    # so it doesn't have a gfx1103 entry. Fall back to gfx1100 (same RDNA3 ISA).
    && ln -sf TensileLibrary_lazy_gfx1100.dat /opt/rocm/lib/rocblas/library/TensileLibrary_lazy_gfx1103.dat \
    && ln -sf TensileLibrary_lazy_gfx1100.dat /opt/rocm/lib/rocblas/library/TensileLibrary_lazy_gfx1102.dat

ENV ROCM_PATH=/opt/rocm
ENV HIP_PATH=/opt/rocm
ENV PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/rocm/lib:/usr/lib/llvm-19/lib:$LD_LIBRARY_PATH

# Copy the whole llama.cpp build (binaries + libs + sources for reference)
COPY --from=build /opt/llama.cpp /opt/llama.cpp
# Remove the build/ dir to save space (binaries are inside the multi-stage COPY
# above, but build/ has intermediate .o files we don't need at runtime)
RUN rm -rf /opt/llama.cpp/build/CMakeFiles /opt/llama.cpp/build/CMakeCache.txt \
    /opt/llama.cpp/build/ggml /opt/llama.cpp/build/common /opt/llama.cpp/build/tools \
    /opt/llama.cpp/build/examples 2>/dev/null || true

# Runtime env (no SDMA for APUs, no SVM pinned memory — both crash on 780M
# with the "host access" error reported in comfyui-rocm-780m issues).
ENV HSA_ENABLE_SDMA=0
ENV HSA_USE_SVM=0
ENV GGML_HIP_GRAPHS=0
# The build path's compiled binaries are at /opt/llama.cpp/build/bin
ENV LLAMA_CPP_BIN=/opt/llama.cpp/build/bin

EXPOSE 8080

WORKDIR /opt/llama.cpp
ENTRYPOINT ["/opt/llama.cpp/build/bin/llama-server"]
CMD ["--help"]
