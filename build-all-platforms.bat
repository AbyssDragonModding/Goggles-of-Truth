@echo off
@echo Building for x86_64-windows...
zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast
@echo Building for x86_64-windows... done.

@echo Building for macos...
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast
@echo Building for macos... done.

@echo Building for macos-aarch64...
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
@echo Building for macos-aarch64... done.

@echo Building for x86_64-linux...
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
@echo Building for x86_64-linux... done.

@echo Building for aarch64-linux...
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast
@echo Building for aarch64-linux... done.