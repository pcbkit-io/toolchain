# PCBKit toolchain

What PCBKit ships that its licences require to be published with its sources: the compilers the
web app runs in your browser to build a board's firmware, each with the recipe that built it and,
in the release of each build, the complete sources it was built from.

The PCBKit app fetches a compiler only when a board needs it, from
`https://library.pcbkit.io/toolchains/<profile>/`; the same files are in this repository's release
of that profile, beside the sources.

| Folder | Profile (release) | What it is | Licences |
|---|---|---|---|
| [`avr/`](avr) | `avr-gcc-15.2.0-pcbkit-2` | avr-gcc 15.2.0 (cc1, cc1plus), binutils 2.45 (as, ld, objcopy) and avr-libc 2.2.1 in WebAssembly, for the ATmega328P and ATmega168P (Arduino Uno, Nano, Pro Mini): C and C++, linked with libgcc, libc and libm; the Arduino platform: ArduinoCore-avr 1.8.8 and the libraries Wire, SPI, EEPROM, SoftwareSerial, Servo, LiquidCrystal, Adafruit GFX, BusIO, SSD1306, SHT31, NeoPixel, Sensirion Core and SCD4x, LedControl, compiled as the Arduino IDE compiles them, and Arduino's ctags for the sketch preprocessor | GCC and binutils GPL-3.0-or-later (libgcc with the GCC Runtime Library Exception); GMP, MPFR, MPC LGPL-3.0-or-later; avr-libc BSD-3-Clause; ArduinoCore-avr, Servo, LiquidCrystal LGPL-2.1-or-later; Adafruit GFX, SSD1306, SHT31 BSD; BusIO, LedControl MIT; NeoPixel LGPL-3.0; Sensirion BSD-3-Clause; ctags GPL-2.0 |

## Building

Each folder has a `Dockerfile` (the build environment, pinned by digest) and a `build.sh` that
downloads the sources listed in its `sources.txt`, checks their SHA-256 and builds everything from
them:

```sh
docker build -t pcbkit-avr avr
docker run --rm -v "$PWD/avr:/recipe" -v "$PWD/out/avr:/dist" pcbkit-avr /recipe/build.sh /dist
```

`out/avr/manifest.txt` lists every file built with its size and SHA-256; PCBKit pins those of the
files it serves (`packages/firmware-compiler/avr.ts` in the PCBKit repository) and its build turns
`sysroot/` into the one archive the browser reads (`sdk.bin`).

## Releases

A release is named after its profile and carries:

- the files the app serves (`cc1.js`, `cc1.wasm`, …, `sdk.bin`) and `manifest.txt`;
- the sources exactly as their projects publish them (`gcc-15.2.0.tar.xz`, …), with their
  licence texts (`licenses/`).

## Other compilers PCBKit serves

Clang/LLD 19 for RISC-V and Cortex-M (`clang-19.1.7-pcbkit-4`) and Espressif's Clang/LLD 22 for
the ESP32-S3 (`esp-clang-22.1.4-pcbkit-1`) are under the Apache License 2.0 with LLVM exception,
their C library (picolibc) under BSD-style licences: they are built by recipes in the PCBKit
repository (`tools/machine/`) and served with their notices (`NOTICE.json`).
