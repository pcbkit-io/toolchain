# The AVR toolchain's build environment: Emscripten 4.0.22 (pinned by digest, arm64 and amd64) and
# the host tools GCC's and binutils' builds need. Nothing of this image is shipped but what
# build.sh compiles from the sources in sources.txt.
FROM emscripten/emsdk:4.0.22@sha256:a08b927777707813e64af195db105f935bd554f5825606b2048031151a9635f5
RUN apt-get update && apt-get install -y --no-install-recommends \
      bison flex texinfo xz-utils bzip2 curl ca-certificates make gcc g++ python3 file \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
