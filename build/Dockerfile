# Dockerfile for llama.cpp + ROCm 7.13 (TheRock gfx110X-all wheels) on Radeon 780M (gfx1103)
#
# Multi-stage build:
#   - build:    installs TheRock ROCm 7.13 wheels via pip (core,
#               devel, libraries-gfx110X-all). Uses pip because the
#               wheels' file layout is wheel-format-specific (relative
#               symlinks, dist-info, etc.) and TheRock's _rocm_sdk_*
#               directory layout breaks when files are renamed or
#               moved around. pip knows how to install them.
#   - runtime:  Only the final /opt/rocm (real files, no symlinks
#               to wheel locations) + llama.cpp binaries.
#
# TheRock wheels: https://rocm.nightlies.amd.com/v2/gfx110X-all/
# ROCm 7.13.0a20260513 - the same version ComfyUI on this host uses.
# Native gfx1103 - no HSA_OVERRIDE_GFX_VERSION shim, no gfx1100
# emulation.
#
# Build:
#   cd /opt/llama.cpp-rocm-780m/build
#   docker build -f Dockerfile.therock -t llama.cpp-rocm-780m:7.13-therock .
#
# The build context must include a "therock-wheels/" directory
# with the three pre-downloaded wheels:
#   rocm_sdk_core-7.13.0a20260513-py3-none-linux_x86_64.whl
#   rocm_sdk_devel-7.13.0a20260513-py3-none-linux_x86_64.whl
#   rocm_sdk_libraries_gfx110X_all-7.13.0a20260513-py3-none-linux_x86_64.whl
# (and their dist-info wheels, which is just the underscore-prefixed
# metadata packages).
#
# The wheels' rocm-sdk-libraries-gfx110X-all are 2.7 GB,
# rocm-sdk-core 1.5 GB, rocm-sdk-devel contains _devel.tar (9 GB)
# that pip extracts to a real /opt/rocm-style layout at install time.

# ============================================================================
# Build stage
# ============================================================================
FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates python3-pip \
        cmake ninja-build git pkg-config g++ gcc \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install TheRock wheels offline. We use --no-index --find-links
# instead of --index-url so we don't depend on the CloudFront
# index being reachable at build time.
#
# The order matters:
#   1) rocm-sdk-core first (provides _rocm_sdk_core/, baseline)
#   2) rocm-sdk-devel second (adds _rocm_sdk_devel/, headers, bitcode)
#   3) rocm-sdk-libraries-gfx110X-all last (adds _rocm_sdk_libraries_gfx110X_all/,
#      real .so.1 files for hipblas/rocblas/miopen/rccl, gfx1103 code objects)
#
# The SDK uses a multi-package Python distribution layout: each
# wheel contributes a subdirectory under site-packages, and the
# actual ROCm install layout is created lazily on first import.
# `python -c 'import rocm_sdk'` materialises /opt/rocm/ via
# `_dist_info.py:install()`.
ENV PIP_NO_INDEX=1
COPY therock-wheels/ /tmp/therock-wheels/
RUN pip install --no-index --break-system-packages --find-links /tmp/therock-wheels \
        rocm-sdk-core==7.13.0a20260513 \
        rocm-sdk-devel==7.13.0a20260513 \
        rocm-sdk-libraries-gfx110x-all==7.13.0a20260513

# Trigger the lazy /opt/rocm/ materialisation. The `rocm-sdk init`
# console script (defined by rocm_sdk_core) expands everything from
# site-packages/_rocm_sdk_* into a real /opt/rocm/ tree.
# Materialise /opt/rocm/. The TheRock wheels are a *distribution*
# format, not a runtime install - they sit in site-packages and
# need to be assembled into a /opt/rocm/ tree at use time.
#
# The order matters:
#   1) libraries FIRST (real .so.1 for hipblas/rocblas/miopen/rccl,
#      gfx1103 kernels)
#   2) core SECOND (real libamdhip64.so.7, libhsa, libomp, headers)
#   3) devel LAST, picking only the bits that don't conflict:
#      - include/ (additive, no conflicts)
#      - lib/llvm/ (bitcode, no conflicts with .so)
#      - lib/host-math/, lib/hipblaslt/, lib/hipdnn_plugins/,
#        lib/cmake/ (additive)
#      - bin/ (additive)
#      - lib/*.so* (NOT copied - those are wheel-style relative
#        symlinks that would overwrite the real files from core/
#        libraries; the real files already cover them)
RUN set -eux; \
    mkdir -p /opt/rocm; \
    SITE=$(python3 -c "import site; print(site.getsitepackages()[0])"); \
    echo "site-packages: $SITE"; \
    ls -d "$SITE/_rocm_sdk_"*; \
    # The devel wheel is special: it ships an embedded _devel.tar that
    # contains _rocm_sdk_devel/{include,lib,bin,...}. pip install
    # only extracts the tarball itself, not its contents. We must
    # untar manually to expose headers and bitcode.
    if [ -f "$SITE/rocm_sdk_devel/_devel.tar" ]; then \
        echo "Extracting _devel.tar..."; \
        tar -xf "$SITE/rocm_sdk_devel/_devel.tar" -C "$SITE/"; \
    fi; \
    ls -d "$SITE/_rocm_sdk_devel"; \
    # Order matters: copy devel FIRST (adds headers, bitcode,
    # bin/hipcc symlink, lib/cmake, etc). Then copy libraries
    # which has real .so.1 files for hipblas/rocblas/miopen/rccl —
    # these overwrite any symlinks the devel wheel would have
    # placed. Then copy core (real libamdhip64.so.7, libhsa,
    # libomp, headers) which again overwrites.
    # After all three cp's, the only remaining symlinks are
    # inter-/opt/rocm/ ones (e.g. bin/hipcc -> ../lib/llvm/bin/...)
    # which work fine because everything is now under /opt/rocm/.
    mkdir -p /opt/rocm; \
    # Skip devel/include/ - all files there are symlinks back to
    # _rocm_sdk_core/include/. The real headers come from core's
    # include/ which is copied below. \
    # cp -a "$SITE/_rocm_sdk_devel/include/."  /opt/rocm/include/; \
    mkdir -p /opt/rocm/lib; \
    # Skip devel/lib/hipblaslt/, lib/host-math/, lib/llvm/,
    # lib/hipdnn_plugins/, lib/oam/, lib/rocfft/, etc. - these
    # have wheel-style relative symlinks for their .so files.
    # Copy ONLY devel/lib/cmake/ (all real files) since we need
    # the CMake package configs (hip-lang-config.cmake, etc.) for
    # building. Do this BEFORE the libraries copy so it doesn't
    # conflict. \
    if [ -d "$SITE/_rocm_sdk_devel/lib/cmake" ]; then \
        cp -a "$SITE/_rocm_sdk_devel/lib/cmake/." /opt/rocm/lib/cmake/; \
    fi; \
    # The devel wheel also ships CMake configs under \
    # lib/llvm/lib/cmake/ (e.g. AMDDeviceLibsConfig.cmake). These \
    # are NOT in core, only in devel. Copy them too. \
    if [ -d "$SITE/_rocm_sdk_devel/lib/llvm/lib/cmake" ]; then \
        mkdir -p /opt/rocm/lib/llvm/lib/cmake; \
        cp -a "$SITE/_rocm_sdk_devel/lib/llvm/lib/cmake/." /opt/rocm/lib/llvm/lib/cmake/; \
    fi; \
    mkdir -p /opt/rocm/bin; \
    cp -a "$SITE/_rocm_sdk_libraries_gfx110X_all/." /opt/rocm/; \
    # core has the real .so.1 files for hipblas/rocblas/miopen/rccl, \
    # real libamdhip64.so.7, libhsa, libomp, headers, and a \
    # lib/llvm/ with clang/clang++/bitcode. The devel wheel adds \
    # extra headers and bitcode that we don't need at runtime. \
    cp -a "$SITE/_rocm_sdk_core/."                 /opt/rocm/; \
    # The devel wheel ships additional headers under include/ \
    # (hipblas, hiprand, rocrand, rocsparse, etc.) that are not \
    # in core. MOST are real files but a few are wheel-style \
    # symlinks to core. Copy them AFTER core, with `--no-dereference` \
    # to avoid "not writing through dangling symlink" errors on \
    # the symlink files (cp will skip those). \
    if [ -d "$SITE/_rocm_sdk_devel/include" ]; then \
        # Copy ONLY files that don't already exist in /opt/rocm/include/. \
        # This skips the wheel-style symlinks to core (which are \
        # redundant - core's real files are already there) while \
        # adding the new headers (hipblas/, hiprand/, etc.) that core \
        # doesn't have. \
        (cd "$SITE/_rocm_sdk_devel/include" && \
            find . -type f -o -type l 2>/dev/null | while IFS= read -r item; do \
                target="/opt/rocm/include/${item#./}"; \
                if [ ! -e "$target" ] && [ ! -L "$target" ]; then \
                    mkdir -p "$(dirname "$target")"; \
                    cp -a "$item" "$target" 2>/dev/null || true; \
                fi; \
            done) || true; \
    fi; \
    mkdir -p /opt/rocm/bin; \
    cp -a "$SITE/_rocm_sdk_libraries_gfx110X_all/." /opt/rocm/; \
    cp -a "$SITE/_rocm_sdk_core/."                 /opt/rocm/; \
    # The hip-lang CMake config references the versioned
    # libamdhip64.so.7.13.26183-83e9908b71 file. The core wheel
    # only ships libamdhip64.so.7 (without version suffix), so
    # we need to create the versioned file. This is the same
    # symlink that the devel wheel has as
    #   lib/libamdhip64.so.7.13.26183-83e9908b71 -> libamdhip64.so.7
    # but we copy the real file to satisfy CMake's
    # IMPORTED_LOCATION check, which doesn't follow symlinks. \
    if [ -f /opt/rocm/lib/libamdhip64.so.7 ]; then \
        cp -L /opt/rocm/lib/libamdhip64.so.7 /opt/rocm/lib/libamdhip64.so.7.13.26183-83e9908b71; \
    fi; \
    # The devel wheel ships many .so files that are symlinks \
    # back to _rocm_sdk_core/lib/ or _rocm_sdk_libraries_*all/lib/. \
    # Since we've already copied the real .so.X files (without \
    # .Y.Z subversions and without the bare .so unversioned name) \
    # from core + libraries, we need to recreate those symlinks \
    # by reading what the devel wheel expects. \
    for f in "$SITE/_rocm_sdk_devel"/lib/*.so*; do \
        [ -L "$f" ] || continue; \
        # Get the basename \
        base=$(basename "$f"); \
        # Skip if already exists in /opt/rocm/lib/ \
        if [ -e "/opt/rocm/lib/$base" ]; then \
            continue; \
        fi; \
        # Resolve the devel relative symlink. The symlink can \
        # point to: \
        #   - a basename (e.g. libamd_comgr.so.3.0.0 -> \
        #     libamd_comgr.so.3), which is in /opt/rocm/lib/ \
        #     already (from core or libraries copy) \
        #   - a relative path (e.g. libamd_comgr.so.3 -> \
        #     ../../_rocm_sdk_core/lib/libamd_comgr.so.3) \
        #   - an absolute path. \
        target=$(readlink "$f"); \
        # Try the target as a basename in /opt/rocm/lib/ first. \
        if [ -e "/opt/rocm/lib/$(basename "$target")" ]; then \
            ln -s "$(basename "$target")" "/opt/rocm/lib/$base"; \
        elif [[ "$target" == ../../_rocm_sdk_* ]]; then \
            real_base=$(basename "$target"); \
            if [ -e "/opt/rocm/lib/$real_base" ]; then \
                ln -s "$real_base" "/opt/rocm/lib/$base"; \
            fi; \
        fi; \
    done; \
    # Create unversioned symlinks for LLVM libraries that the \
    # hip-lang linker calls with -lXXX but only ship the \
    # versioned libXXX.so.23.0git file. The devel wheel ships \
    # these as symlinks but we don't copy devel/lib/llvm/. \
    for f in /opt/rocm/lib/llvm/lib/*.so.23.0git; do \
        unversioned="${f%.23.0git}"; \
        if [ ! -e "$unversioned" ]; then \
            ln -s "$(basename "$f")" "$unversioned"; \
        fi; \
    done; \
    # After all three, fix up any remaining relative symlinks that
    # point outside /opt/rocm. E.g. devel/bin/hipcc was a symlink
    # to '../../_rocm_sdk_core/bin/hipcc'; after cp the real file
    # is at /opt/rocm/bin/hipcc (from core), but the symlink got
    # overwritten by core's cp. So nothing to do here in practice.
    find /opt/rocm -type l -print0 2>/dev/null | while IFS= read -r -d '' link; do \
        if [ ! -e "$link" ]; then \
            target=$(readlink "$link"); \
            echo "WARN: dangling symlink: $link -> $target"; \
        fi; \
    done || true; \
    ls -la /opt/rocm/bin/hipcc \
              /opt/rocm/lib/hipblaslt/library/TensileLiteLibrary_lazy_gfx1103_Mapping.dat \
              /opt/rocm/lib/llvm/lib/libomp.so \
              /opt/rocm/lib/libamdhip64.so.7
# Sanity check: bitcode for gfx1103 must be present
RUN ls /opt/rocm/lib/llvm/amdgcn/bitcode/ | grep -E "gfx1103|1103" | head -3

# Zen 4 / znver4 CPU flags
ENV CFLAGS="-O3 -DNDEBUG -march=znver4 -mtune=znver4 -fopenmp -fstack-protector-strong"
ENV CXXFLAGS="-O3 -DNDEBUG -march=znver4 -mtune=znver4 -fopenmp -fstack-protector-strong"
ENV LDFLAGS="-fopenmp"

# Clone and build llama.cpp master
WORKDIR /opt/llama.cpp
ARG LLAMA_CPP_REF=master
RUN git clone --depth 1 --branch ${LLAMA_CPP_REF} https://github.com/ggml-org/llama.cpp.git .

# ROCM_PATH and HIP_PATH are unset because the TheRock wheels
# detect them via Python site-packages and would otherwise look
# in /usr/local/lib/.../site-packages/_rocm_sdk_core, NOT
# /opt/rocm/. We have already materialised the SDK at /opt/rocm
# and CMAKE_PREFIX_PATH tells CMake where to find it.
ENV ROCM_PATH=
ENV HIP_PATH=
ENV PATH=/opt/rocm/bin:/opt/rocm/lib/llvm/bin:$PATH

RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=gcc \
        -DCMAKE_CXX_COMPILER=g++ \
        -DCMAKE_HIP_COMPILER=/opt/rocm/lib/llvm/bin/clang++ \
        -DCMAKE_PREFIX_PATH=/opt/rocm \
        -DGGML_HIP=ON -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_OPENMP=ON \
        -DGGML_NATIVE=OFF \
        -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
        -DGGML_AVX512=ON -DGGML_AVX512_VBMI=ON -DGGML_AVX512_VNNI=ON -DGGML_AVX512_BF16=ON \
        -DAMDGPU_TARGETS="gfx1103" \
    && cmake --build build --config Release -j$(nproc)

# Verify build
RUN LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib/llvm/lib \
        /opt/llama.cpp/build/bin/llama-server --version \
    && LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib/llvm/lib \
        /opt/llama.cpp/build/bin/llama-cli --version \
    && ls /opt/llama.cpp/build/bin/

# ============================================================================
# Runtime stage
# ============================================================================
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libgomp1 libomp5-19 libgfortran5 libssl3 libstdc++6 libgcc-s1 \
        libatomic1 libquadmath0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/lib/llvm-19/lib/libomp.so.5 /usr/lib/x86_64-linux-gnu/libomp.so

# Copy the ROCm install + llama.cpp binaries from the build stage
COPY --from=build /opt/rocm /opt/rocm
COPY --from=build /opt/llama.cpp /opt/llama.cpp
RUN rm -rf /opt/llama.cpp/build/CMakeFiles /opt/llama.cpp/build/CMakeCache.txt \
        /opt/llama.cpp/build/ggml /opt/llama.cpp/build/common \
        /opt/llama.cpp/build/tools /opt/llama.cpp/build/examples 2>/dev/null || true

ENV ROCM_PATH=/opt/rocm
ENV HIP_PATH=/opt/rocm
ENV PATH=/opt/rocm/bin:/opt/rocm/lib/llvm/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib/llvm/lib

# Runtime env: gfx1103 is natively supported by TheRock wheels.
ENV HSA_ENABLE_SDMA=0
ENV HSA_USE_SVM=0
ENV GGML_HIP_GRAPHS=0

EXPOSE 8080
WORKDIR /opt/llama.cpp
ENTRYPOINT ["/opt/llama.cpp/build/bin/llama-server"]
CMD ["--help"]
