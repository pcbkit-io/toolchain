#!/bin/bash
# The AVR toolchain PCBKit runs in the browser, built from the sources in sources.txt:
#   docker build -t pcbkit-avr avr && docker run --rm -v $PWD/avr:/recipe -v $PWD/out:/dist pcbkit-avr /recipe/build.sh
# (sources/ beside this file, if present, is used instead of downloading.)
#
# GCC's driver fork()s and exec()s cc1, as and ld, which a browser cannot do: what runs there are
# the programs themselves, chained by the page (PCBKit's packages/firmware-compiler). This builds:
#   1. binutils, GCC (C, C++) and avr-libc for AVR natively: the target's libraries (libgcc,
#      libc, libm, the devices' start-up objects) and the linker scripts, compiled once here;
#   2. GMP, MPFR and MPC, then cc1 and cc1plus from the same GCC source to WebAssembly;
#   3. as, ld and objcopy from the same binutils source to WebAssembly;
#   4. the sysroot the WebAssembly tools read (headers, libraries, linker scripts);
#   5. the Arduino platform: ArduinoCore-avr and the libraries in sources.txt compiled for each
#      processor as the Arduino IDE compiles them (its platform.txt flags, without LTO), their
#      headers and archives in the sysroot, and arduino/libraries.txt (name, version, include
#      directory, archive, licence of each);
#   6. Arduino's ctags in WebAssembly (the sketch preprocessor's function prototypes);
#   7. the sources' licences.
# /dist receives: cc1.js, cc1.wasm, cc1plus.js, cc1plus.wasm, avr-as.js, avr-ld.js, objcopy.js,
# ctags.js, sysroot/, licenses/, manifest.txt (each file's size, SHA-256 and path).
# On a host that built it before: -v <its /build>:/build in an image committed after that build
# (the native toolchain in /opt) rebuilds only what changed.
set -euo pipefail
recipe=$(cd "$(dirname "$0")" && pwd)
dist=${1:-/dist}
jobs=$(nproc)
mkdir -p "$dist" /build /opt/avr /opt/wasmdeps
cd /build

# ── The sources, checked ─────────────────────────────────────────────────────────────────────
while read -r name url sha; do
  case $name in ''|'#'*) continue ;; esac
  if [ -f "$recipe/sources/$name" ]; then cp "$recipe/sources/$name" .; elif [ ! -f "$name" ]; then curl -fsSL -o "$name" "$url"; fi
  echo "$sha  $name" | sha256sum -c --quiet
  dir=${name%.tar.*}
  [ -d "$dir" ] || tar -xf "$name"
done < "$recipe/sources.txt"
gcc=/build/gcc-15.2.0 binutils=/build/binutils-2.45 avrlibc=/build/avr-libc-2.2.1
build=$("$gcc/config.guess")
# GCC builds GMP, MPFR and MPC with itself when their sources sit in its tree.
for d in gmp-6.3.0 mpfr-4.2.1 mpc-1.3.1; do ln -sfn "/build/$d" "$gcc/${d%%-*}"; done
for s in "$binutils" "$gcc"; do sed -i '/^development=/s/true/false/' "$s/bfd/development.sh" 2>/dev/null || true; done

# ── 1. The native AVR toolchain: the target's libraries ───────────────────────────────────────
export PATH=/opt/avr/bin:$PATH
if [ ! -x /opt/avr/bin/avr-ld ]; then
  mkdir -p native-binutils && cd native-binutils
  "$binutils/configure" --target=avr --prefix=/opt/avr --disable-nls --disable-werror --disable-gdb --disable-gdbserver --disable-sim --disable-gprofng --disable-doc
  make -j"$jobs" && make install
  cd /build
fi
if [ ! -x /opt/avr/bin/avr-gcc ]; then
  mkdir -p native-gcc && cd native-gcc
  "$gcc/configure" --build="$build" --host="$build" --target=avr --prefix=/opt/avr \
    --enable-languages=c,c++ --disable-bootstrap --disable-nls --disable-shared --disable-threads \
    --disable-libssp --disable-libada --disable-libquadmath --disable-libgomp --disable-libvtv \
    --disable-libstdcxx --disable-lto --with-dwarf2 MAKEINFO=missing
  make -j"$jobs" all-gcc all-target-libgcc && make install-gcc install-target-libgcc
  cd /build
fi
if [ ! -f /opt/avr/avr/lib/avr5/libc.a ]; then
  mkdir -p native-avr-libc && cd native-avr-libc
  "$avrlibc/configure" --build="$build" --host=avr --prefix=/opt/avr
  make -j"$jobs" && make install
  cd /build
fi

# ── 2. cc1 and cc1plus in WebAssembly ─────────────────────────────────────────────────────────
# CC_FOR_BUILD stays native (the generator programs run during the build). Emscripten's musl has
# psignal(const char*): -DHAVE_PSIGNAL keeps libiberty's own out. CODY_NETWORKING=0 keeps C++
# modules' mapper (libcody) off sockets: a page has none. AR's plugin probe would ask for an LTO
# plugin that does not exist here.
printf 'am_cv_ar_has_plugin=no\nam_cv_ranlib_has_plugin=no\n' > /build/emsc-site
export CONFIG_SITE=/build/emsc-site CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ HOST_CC=gcc BUILD_CC=gcc
host_flags="-DHAVE_PSIGNAL=1 -DCODY_NETWORKING=0 -DELIDE_CODE -Os"
if [ ! -f /opt/wasmdeps/lib/libmpc.a ]; then
  (cd gmp-6.3.0 && emconfigure ./configure --build="$build" --host=wasm32 --prefix=/opt/wasmdeps --disable-shared --enable-static --disable-assembly CC_FOR_BUILD=gcc && emmake make -j"$jobs" && emmake make install && make distclean)
  (cd mpfr-4.2.1 && emconfigure ./configure --build="$build" --host=wasm32 --prefix=/opt/wasmdeps --disable-shared --enable-static --with-gmp=/opt/wasmdeps && emmake make -j"$jobs" && emmake make install && make distclean)
  (cd mpc-1.3.1 && emconfigure ./configure --build="$build" --host=wasm32 --prefix=/opt/wasmdeps --disable-shared --enable-static --with-gmp=/opt/wasmdeps --with-mpfr=/opt/wasmdeps && emmake make -j"$jobs" && emmake make install && make distclean)
fi
# The in-tree links served the native build; the WebAssembly one takes the libraries built above.
for d in gmp mpfr mpc; do rm -f "$gcc/$d"; done
mkdir -p wasm-gcc && cd wasm-gcc
[ -f Makefile ] || emconfigure "$gcc/configure" --build="$build" --host=wasm32 --target=avr --prefix=/opt/avr-wasm \
  --enable-languages=c,c++ --with-gmp=/opt/wasmdeps --with-mpfr=/opt/wasmdeps --with-mpc=/opt/wasmdeps \
  --disable-bootstrap --disable-shared --disable-threads --disable-nls --disable-libssp --disable-libada \
  --disable-libquadmath --disable-libgomp --disable-libvtv --disable-libstdcxx --disable-lto \
  --without-headers --disable-werror MAKEINFO=missing
# The prerequisites (generators, libbackend, the host libraries) with plain flags: auxiliary tools
# that need what Emscripten lacks (gcov-tool: ftw) fail here and are not shipped.
emmake make -O -j"$jobs" all-gcc "CFLAGS=$host_flags" "CXXFLAGS=$host_flags" || true
# The compilers proper as modules that expose FS and callMain, their .wasm beside them.
rm -f gcc/cc1 gcc/cc1plus
emmake make -O -j"$jobs" -C gcc cc1 cc1plus "CFLAGS=$host_flags" "CXXFLAGS=$host_flags" \
  "LDFLAGS=-sMODULARIZE=1 -sEXPORT_NAME=createModule -sFORCE_FILESYSTEM=1 -sEXPORTED_RUNTIME_METHODS=FS,callMain -sALLOW_MEMORY_GROWTH=1 -sUSE_ZLIB=1 -sINITIAL_MEMORY=64MB -sMAXIMUM_MEMORY=2GB -sSTACK_SIZE=8MB"
for t in cc1 cc1plus; do install -D "gcc/$t" "$dist/$t.js"; install -D "gcc/$t.wasm" "$dist/$t.wasm"; done
cd /build

# ── 3. as, ld and objcopy in WebAssembly ──────────────────────────────────────────────────────
mkdir -p wasm-binutils && cd wasm-binutils
[ -f Makefile ] || emconfigure "$binutils/configure" --target=avr --host=wasm32 --enable-ld=default \
  --enable-default-execstack=no --enable-deterministic-archives --disable-doc --disable-gprof \
  --disable-gprofng --disable-nls --disable-gdb --disable-gdbserver --disable-libdecnumber \
  --disable-readline --disable-sim --disable-werror
# Everything with plain flags first (the sub-configures link test programs), then the three
# programs relinked as single-file modules exposing FS.
emmake make -O -j"$jobs" "CFLAGS=$host_flags"
rm -f gas/as-new ld/ld-new binutils/objcopy
single="-sMODULARIZE=1 -sFORCE_FILESYSTEM=1 -sEXPORTED_RUNTIME_METHODS=FS -sSINGLE_FILE=1 -sALLOW_MEMORY_GROWTH=1 -sUSE_ZLIB=1"
emmake make -O -j"$jobs" -C gas "CFLAGS=$host_flags" "LDFLAGS=$single" as-new
emmake make -O -j"$jobs" -C ld "CFLAGS=$host_flags" "LDFLAGS=$single" ld-new
emmake make -O -j"$jobs" -C binutils "CFLAGS=$host_flags" "LDFLAGS=$single" objcopy
install -D gas/as-new "$dist/avr-as.js"
install -D ld/ld-new "$dist/avr-ld.js"
install -D binutils/objcopy "$dist/objcopy.js"
cd /build

# ── 4. The sysroot and the licences ──────────────────────────────────────────────────────────
# The architectures of the processors PCBKit models: avr5 (ATmega328P, ATmega168P, ATmega32U4),
# avr6 (ATmega2560: 256 KiB, a 3-byte PC) and avr25 (ATtiny85, ATtiny84): avr-libc's headers,
# libraries and start-up objects, libgcc, GCC's own headers, the linker scripts.
archs="avr5 avr6 avr25"
rm -rf "$dist/sysroot" "$dist/licenses"
mkdir -p "$dist/sysroot/avr/lib" "$dist/sysroot/gcc-include"
cp -a /opt/avr/avr/include "$dist/sysroot/avr/include"
cp -a /opt/avr/avr/lib/ldscripts "$dist/sysroot/avr/lib/"
for a in $archs; do
  cp -a "/opt/avr/avr/lib/$a" "$dist/sysroot/avr/lib/"
  install -D -m 644 "/opt/avr/lib/gcc/avr/15.2.0/$a/libgcc.a" "$dist/sysroot/libgcc/$a/libgcc.a"
done
cp -a /opt/avr/lib/gcc/avr/15.2.0/include/. /opt/avr/lib/gcc/avr/15.2.0/include-fixed/. "$dist/sysroot/gcc-include/"

# ── 5. The Arduino platform ──────────────────────────────────────────────────────────────────
# Two platforms: ArduinoCore-avr (the Nano, Pro Mini, Leonardo and Mega 2560) and ATTinyCore
# (the ATtiny85 and ATtiny84, with its own Wire, SPI, EEPROM, SoftwareSerial and Servo over the
# USI and the tinies' timers). Per board: the core as libcore.a and each library as lib<name>.a,
# compiled with that core's platform.txt and boards.txt flags for the board in lib/<mcu><suffix>
# (BUILDS below), but without -flto: the browser links with ld alone. A library's sources are its
# src/ tree (Arduino's 1.5 format) or its top level and utility/ (the older one); every library's
# include directory of the platform is on every compile, as the IDE resolves a library's own
# includes. arduino/libraries.txt: platform, name, version, include directory, archive, licence.
core=/build/ArduinoCore-avr-1.8.8 tinycore=/build/ATTinyCore-1.5.2/avr
arduino="$dist/sysroot/arduino"
mkdir -p "$arduino/cores" "$arduino/variants" "$arduino/libraries" "$arduino/tiny/libraries"
cp -a "$core/cores/arduino" "$arduino/cores/arduino"
cp -a "$tinycore/cores/tiny" "$arduino/cores/tiny"
find "$arduino/cores" -type f ! -name '*.h' ! -name new -delete
for v in standard eightanaloginputs leonardo mega; do install -D -m 644 "$core/variants/$v/pins_arduino.h" "$arduino/variants/$v/pins_arduino.h"; done
for v in tinyX5 tinyX4_reverse; do install -D -m 644 "$tinycore/variants/$v/pins_arduino.h" "$arduino/variants/$v/pins_arduino.h"; done
external=""
for l in LiquidCrystal-1.0.7 Adafruit-GFX-Library-1.13.0 Adafruit_BusIO-1.17.4 Adafruit_SSD1306-2.5.17 Adafruit_SHT31-2.2.2 Adafruit_NeoPixel-1.15.5 arduino-core-0.7.3 arduino-i2c-scd4x-1.1.0 LedControl-1.0.6; do external="$external /build/$l"; done
# Each platform's libraries: its core's own, then the ones every AVR shares (ArduinoCore-avr's
# Servo drives a 16-bit Timer1; the tinies take ATTinyCore's).
libraries_avr="$core/libraries/Wire $core/libraries/SPI $core/libraries/EEPROM $core/libraries/SoftwareSerial /build/Servo-1.3.0$external"
libraries_tiny="$tinycore/libraries/Wire $tinycore/libraries/SPI $tinycore/libraries/EEPROM $tinycore/libraries/SoftwareSerial $tinycore/libraries/Servo_ATTinyCore$external"
property() { sed -n "s/^$2=//p" "$1/library.properties" | tr -d '\r' | head -1; }
sources() { # a library's sources, in a stable order
  if [ -d "$1/src" ]; then find "$1/src" -name '*.c' -o -name '*.cpp' -o -name '*.S'
  else find "$1" -maxdepth 1 \( -name '*.c' -o -name '*.cpp' -o -name '*.S' \); [ -d "$1/utility" ] && find "$1/utility" -name '*.c' -o -name '*.cpp' -o -name '*.S'
  fi | LC_ALL=C sort
}
name_of() { property "$1" name | tr -c 'A-Za-z0-9_\n' _; }
# Where a library's headers go: a platform's own libraries under tiny/ for ATTinyCore, the
# shared ones once under libraries/.
include_of() { # platform, library
  local base=libraries; case $2 in "$tinycore"/*) base=tiny/libraries ;; esac
  if [ -d "$2/src" ]; then echo "$base/$(name_of "$2")/src"; else echo "$base/$(name_of "$2")"; fi
}
printf '# platform name version include archive licence\n' > "$arduino/libraries.txt"
for platform in avr tiny; do
  eval "libraries=\$libraries_$platform"
  for l in $libraries; do
    include=$(include_of $platform "$l")
    if [ -d "$l/src" ]; then from="$l/src"; else from="$l"; fi
    if [ ! -d "$arduino/$include" ]; then
      (cd "$from" && find . \( -path ./examples -o -path ./fontconvert -o -path ./extras \) -prune -o \( -name '*.h' -o -name '*.hpp' -o -name '*.inc' \) -print | LC_ALL=C sort | while read -r h; do install -D -m 644 "$h" "$arduino/$include/${h#./}"; done)
    fi
    licence=$(ls "$l" | grep -iE '^(license|licence|copying)' | head -1 || true)
    printf '%s %s %s %s lib%s.a %s\n' $platform "$(name_of "$l")" "$(property "$l" version)" "$include" "$(name_of "$l")" "${licence:--}" >> "$arduino/libraries.txt"
  done
done
# mcu, clock, board, suffix, platform, variant, extra flags of the board.
BUILDS="
atmega328p 16000000 AVR_NANO - avr eightanaloginputs -
atmega168p 16000000 AVR_NANO - avr eightanaloginputs -
atmega328p 8000000 AVR_PRO -8mhz avr eightanaloginputs -
atmega168p 8000000 AVR_PRO -8mhz avr eightanaloginputs -
atmega32u4 16000000 AVR_LEONARDO - avr leonardo usb
atmega2560 16000000 AVR_MEGA2560 - avr mega -
attiny85 8000000 AVR_ATTINYX5 - tiny tinyX5 -DCLOCK_SOURCE=0,-DNEOPIXELPORT=PORTB
attiny85 16000000 AVR_ATTINYX5 -16mhz tiny tinyX5 -DCLOCK_SOURCE=6,-DNEOPIXELPORT=PORTB
attiny84 8000000 AVR_ATTINYX4 - tiny tinyX4_reverse -DCLOCK_SOURCE=0,-DNEOPIXELPORT=PORTA
"
echo "$BUILDS" | while read -r mcu clock board suffix platform variant extra; do
  [ -n "$mcu" ] || continue
  [ "$suffix" = - ] && suffix=
  lib=$mcu$suffix
  out=/build/arduino-$lib && rm -rf "$out" "$arduino/lib/$lib" && mkdir -p "$out" "$arduino/lib/$lib"
  eval "libraries=\$libraries_$platform"
  defines=(-mmcu=$mcu -DF_CPU=${clock}L -DARDUINO=10819 -DARDUINO_$board -DARDUINO_ARCH_AVR)
  # The Leonardo's USB descriptor (boards.txt: build.usb_flags).
  case $extra in
    usb) defines+=(-DUSB_VID=0x2341 -DUSB_PID=0x8036 '-DUSB_MANUFACTURER="Unknown"' '-DUSB_PRODUCT="Arduino Leonardo"') ;;
    -) ;;
    *) IFS=, read -r -a more <<< "$extra"; defines+=("${more[@]}") ;;
  esac
  if [ $platform = tiny ]; then includes=(-I"$tinycore/cores/tiny" -I"$tinycore/variants/$variant"); corefiles=$tinycore/cores/tiny
  else includes=(-I"$core/cores/arduino" -I"$core/variants/$variant"); corefiles=$core/cores/arduino; fi
  for l in $libraries; do if [ -d "$l/src" ]; then includes+=(-I"$l/src"); else includes+=(-I"$l"); fi; done
  cflags=(-c -Os -w -std=gnu11 -ffunction-sections -fdata-sections "${defines[@]}")
  # ATTinyCore's C sources define variables in headers (USI_TWI_Slave.h), as GCC before 10 let C
  # do by default (common symbols): its platform keeps them common.
  [ $platform = tiny ] && cflags+=(-fcommon)
  cxxflags=(-c -Os -w -std=gnu++11 -fpermissive -fno-exceptions -ffunction-sections -fdata-sections -fno-threadsafe-statics -Wno-error=narrowing "${defines[@]}")
  sflags=(-c -x assembler-with-cpp "${defines[@]}")
  archive() { # the archive's name, then its sources
    local name=$1 dir="$out/$1" objects=() f o; shift; mkdir -p "$dir"
    for f in "$@"; do
      o="$dir/$(echo "${f#/build/}" | tr / _).o"
      case $f in *.c) avr-gcc "${cflags[@]}" "${includes[@]}" "$f" -o "$o" ;; *.cpp) avr-g++ "${cxxflags[@]}" "${includes[@]}" "$f" -o "$o" ;; *.S) avr-gcc "${sflags[@]}" "${includes[@]}" "$f" -o "$o" ;; esac
      objects+=("$o")
    done
    avr-ar rcsD "$arduino/lib/$lib/lib$name.a" "${objects[@]}"
  }
  archive core $(find "$corefiles" -name '*.c' -o -name '*.cpp' -o -name '*.S' | LC_ALL=C sort)
  for l in $libraries; do archive "$(name_of "$l")" $(sources "$l"); done
done

# ── 6. Arduino's ctags in WebAssembly ────────────────────────────────────────────────────────
# The sketch preprocessor runs it over the concatenated .ino files as arduino-cli does
# (ctags -u --language-force=c++ -f - --c++-kinds=svpf --fields=KSTtzns --line-directives).
if [ ! -f /build/wasm-ctags/ctags ]; then
  rm -rf /build/wasm-ctags && cp -a /build/ctags-5.8-arduino11 /build/wasm-ctags && cd /build/wasm-ctags
  emconfigure ./configure --build="$build" --host=wasm32 --disable-etags --disable-external-sort
  emmake make -j"$jobs" CFLAGS=-Os "LDFLAGS=$single"
  cd /build
fi
install -D /build/wasm-ctags/ctags "$dist/ctags.js"

# ── 7. The licences ──────────────────────────────────────────────────────────────────────────
for s in gcc-15.2.0 binutils-2.45 gmp-6.3.0 mpfr-4.2.1 mpc-1.3.1 avr-libc-2.2.1 ctags-5.8-arduino11 ArduinoCore-avr-1.8.8 ATTinyCore-1.5.2 Servo-1.3.0 LiquidCrystal-1.0.7 Adafruit-GFX-Library-1.13.0 Adafruit_BusIO-1.17.4 Adafruit_SSD1306-2.5.17 Adafruit_SHT31-2.2.2 Adafruit_NeoPixel-1.15.5 arduino-core-0.7.3 arduino-i2c-scd4x-1.1.0 LedControl-1.0.6; do
  mkdir -p "$dist/licenses/$s"
  for f in /build/$s/COPYING* /build/$s/LICENSE* /build/$s/LICENCE* /build/$s/license* /build/$s/README*; do [ -f "$f" ] && cp "$f" "$dist/licenses/$s/"; done
done
cp "$recipe/sources.txt" "$dist/licenses/sources.txt"
(cd "$dist" && find . -type f ! -name manifest.json | sort | while read -r f; do printf '%s %s %s\n' "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" "${f#./}"; done) > "$dist/manifest.txt"
echo "built: $(wc -l < "$dist/manifest.txt") files in $dist"
