ifeq ($(host_arch),aarch64)
# aarch64-w64-mingw32 (Windows on ARM64): GCC's mingw-w64 has no aarch64
# target, so build with the clang/llvm-mingw toolchain. clang + lld + the
# llvm-* binutils come from the build environment's PATH (the Guix profile, or
# a developer-installed llvm-mingw), exactly like the darwin host consumes
# clang-toolchain. `clang --target=$(host)` locates the mingw-w64 sysroot
# (headers + CRT + winpthreads) provided alongside it.
clang_prog=$(shell $(SHELL) $(.SHELLFLAGS) "command -v clang")
clangxx_prog=$(shell $(SHELL) $(.SHELLFLAGS) "command -v clang++")
mingw32_CC=$(clang_prog) --target=$(host)
mingw32_CXX=$(clangxx_prog) --target=$(host)
mingw32_AR=$(shell $(SHELL) $(.SHELLFLAGS) "command -v llvm-ar")
mingw32_NM=$(shell $(SHELL) $(.SHELLFLAGS) "command -v llvm-nm")
mingw32_RANLIB=$(shell $(SHELL) $(.SHELLFLAGS) "command -v llvm-ranlib")
mingw32_STRIP=$(shell $(SHELL) $(.SHELLFLAGS) "command -v llvm-strip")
mingw32_OBJCOPY=$(shell $(SHELL) $(.SHELLFLAGS) "command -v llvm-objcopy")
mingw32_OBJDUMP=$(shell $(SHELL) $(.SHELLFLAGS) "command -v llvm-objdump")

# -fuse-ld=lld must appear in C/CXX flags (not just LDFLAGS) so it reaches
# configure-time conftest links: GMP's AC_PROG_CC links a probe with CC +
# CFLAGS only, and without lld clang would fall back to a GNU ld that cannot
# link a Windows/aarch64 object. Same rationale as the darwin host.
mingw32_CFLAGS=-fuse-ld=lld
mingw32_CXXFLAGS=-fuse-ld=lld
mingw32_LDFLAGS=-fuse-ld=lld
else
# x86_64-w64-mingw32 (and i686): GCC mingw-w64, posix-threads variant.
ifneq ($(shell $(SHELL) $(.SHELLFLAGS) "command -v $(host)-gcc-posix"),)
mingw32_CC := $(host)-gcc-posix
endif
ifneq ($(shell $(SHELL) $(.SHELLFLAGS) "command -v $(host)-g++-posix"),)
mingw32_CXX := $(host)-g++-posix
endif

mingw32_CFLAGS=
mingw32_CXXFLAGS=

ifneq ($(LTO),)
mingw32_AR = $(host_toolchain)gcc-ar
mingw32_NM = $(host_toolchain)gcc-nm
mingw32_RANLIB = $(host_toolchain)gcc-ranlib
endif

# libstdc++ debug assertions (GCC-only; clang/llvm-mingw uses libc++).
mingw32_debug_CPPFLAGS=-D_GLIBCXX_DEBUG -D_GLIBCXX_DEBUG_PEDANTIC
endif

mingw32_release_CFLAGS=-O2
mingw32_release_CXXFLAGS=$(mingw32_release_CFLAGS)

mingw32_debug_CFLAGS=-O1 -g
mingw32_debug_CXXFLAGS=$(mingw32_debug_CFLAGS)

mingw32_cmake_system_name=Windows
mingw32_cmake_system_version=10.0
