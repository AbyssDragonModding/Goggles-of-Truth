@echo off
@echo Building for x86_64-windows...

zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast