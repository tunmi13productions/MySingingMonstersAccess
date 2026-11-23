@echo off
setlocal
REM ---------------------------------------------------------------------------
REM  Jeode build: a11y.dll  (native mod for the Jeode mod loader).
REM
REM  Replaces the Milestone-1 injector path. No inject.exe, no version.dll
REM  proxy, no MinHook, no luaopen_game RVA hook -- Jeode's winhttp.dll proxy
REM  loads us and its scheduler hook marshals our C funcs onto the game thread.
REM
REM  Sources: jeode_a11y.c (Jeode ABI entry) + accessibility_bridge.c (Prism,
REM  reused unchanged) + static lua51 (stack accessors, ABI-compatible with the
REM  game's lua_State, as proven in Milestone 1).
REM
REM  Output is written straight into jeode\msm-a11y\ so that whole folder is a
REM  drop-in for  <MSM>\mods\msm-a11y\.
REM ---------------------------------------------------------------------------

REM  Use an x86 developer environment if one is already set up (CI does this
REM  with ilammy/msvc-dev-cmd); otherwise find Visual Studio with vswhere.
if /i "%VSCMD_ARG_TGT_ARCH%"=="x86" goto :have_msvc
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSDIR="
for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%I"
if not defined VSDIR (
    echo ERROR: Visual Studio with C++ tools not found. Install VS 2022 Build Tools with "Desktop development with C++".
    exit /b 1
)
call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" x86 >nul 2>&1
if errorlevel 1 ( echo ERROR: vcvarsall.bat x86 failed & exit /b 1 )
:have_msvc

set ROOT=%~dp0..
set NATIVE=%ROOT%\native
set LUA=%NATIVE%\lua51
set MODDIR=%ROOT%\jeode\msm-a11y
set OBJ=%ROOT%\build\jeode
set MH=%NATIVE%\minhook

if not exist "%MODDIR%" ( echo ERROR: mod folder "%MODDIR%" missing & exit /b 1 )
if not exist "%OBJ%" mkdir "%OBJ%"

REM  A11Y_MILESTONE1 keeps accessibility_bridge.c compiled identically to the
REM  verified M1 build (HUD/nav modules stay out; init.lua drives game reads).
set CFLAGS=/nologo /O2 /W3 /DWIN32 /D_WINDOWS /DA11Y_MILESTONE1 /DLUA_COMPAT_ALL /D_CRT_SECURE_NO_WARNINGS
set INCS=/I"%NATIVE%" /I"%LUA%"

set LUASRC=^
 "%LUA%\lapi.c" "%LUA%\lauxlib.c" "%LUA%\lbaselib.c" "%LUA%\lcode.c" "%LUA%\ldblib.c" ^
 "%LUA%\ldebug.c" "%LUA%\ldo.c" "%LUA%\ldump.c" "%LUA%\lfunc.c" "%LUA%\lgc.c" ^
 "%LUA%\linit.c" "%LUA%\liolib.c" "%LUA%\llex.c" "%LUA%\lmathlib.c" "%LUA%\lmem.c" ^
 "%LUA%\loadlib.c" "%LUA%\lobject.c" "%LUA%\lopcodes.c" "%LUA%\loslib.c" "%LUA%\lparser.c" ^
 "%LUA%\lstate.c" "%LUA%\lstring.c" "%LUA%\lstrlib.c" "%LUA%\ltable.c" "%LUA%\ltablib.c" ^
 "%LUA%\ltm.c" "%LUA%\lundump.c" "%LUA%\lvm.c" "%LUA%\lzio.c"

echo === Building a11y.dll (Jeode native mod) ===
REM  Link to a STAGING path first: if the game is running, the deployed
REM  a11y.dll is locked -- staging lets the compile/link still succeed and
REM  catch code errors, then we copy into the mod folder as a separate step.
cl %CFLAGS% /LD /D_USRDLL %INCS% /Fo"%OBJ%\\" ^
 "%NATIVE%\jeode_a11y.c" "%NATIVE%\accessibility_bridge.c" ^
 "%MH%\src\buffer.c" "%MH%\src\hook.c" "%MH%\src\trampoline.c" "%MH%\src\hde\hde32.c" ^
 %LUASRC% ^
 /link /OUT:"%OBJ%\a11y.dll" kernel32.lib user32.lib
if errorlevel 1 ( echo ERROR: a11y.dll build failed & exit /b 1 )
echo     built OK: %OBJ%\a11y.dll

echo === Deploying a11y.dll into mod folder ===
copy /Y "%OBJ%\a11y.dll" "%MODDIR%\a11y.dll" >nul
if errorlevel 1 (
    echo.
    echo *** Could not copy a11y.dll into the mod folder. ***
    echo *** The game is probably RUNNING and holding a11y.dll open.  ***
    echo *** Close My Singing Monsters, then re-run this script,       ***
    echo *** or copy "%OBJ%\a11y.dll" over "%MODDIR%\a11y.dll" manually.***
    exit /b 1
)

echo === Copying Prism (32-bit prism.dll) into mod folder ===
REM  Built by scripts\Build-Prism.bat into native\prism\.
if exist "%NATIVE%\prism\prism.dll" (
    copy /Y "%NATIVE%\prism\prism.dll" "%MODDIR%\" >nul
) else (
    echo WARNING: native\prism\prism.dll not found. Run scripts\Build-Prism.bat first,
    echo          or the mod will load but stay silent.
)
REM  Tolk and its reader clients are no longer used.
for %%F in (Tolk.dll nvdaControllerClient32.dll SAAPI32.dll dolapi32.dll) do if exist "%MODDIR%\%%F" del /q "%MODDIR%\%%F"

echo.
echo === DONE. Deployable mod folder: %MODDIR% ===
echo     Copy it to  ^<MSM^>\mods\msm-a11y\  (Jeode must already be installed).
dir /b "%MODDIR%"
endlocal
