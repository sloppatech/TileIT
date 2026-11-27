@echo off
rem Release build of tileit: optimised, no debug symbols (no .pdb), unused
rem code removed by the linker. Output: release\tileit.exe
rem
rem Bounds checks stay on on purpose: a clean error beats silent memory
rem corruption on an unexpected input, and they cost little here.

if not exist release mkdir release
odin build . -out:release\tileit.exe -o:speed -disable-assert -vet ^
  -extra-linker-flags:"/DEBUG:NONE /OPT:REF /OPT:ICF"
if errorlevel 1 exit /b 1
if exist release\tileit.pdb del release\tileit.pdb
rem The licences travel with the binary.
copy /y LICENSE release\LICENSE.txt >nul
copy /y THIRD_PARTY_NOTICES.md release\THIRD_PARTY_NOTICES.md >nul
echo Built release\tileit.exe
