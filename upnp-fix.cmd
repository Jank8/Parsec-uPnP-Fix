@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Parsec uPnP Fix - CMD edition

REM ===========================================================================
REM  Parsec uPnP Fix - pure CMD edition (uses only built-in curl.exe)
REM
REM  Usage:
REM      upnp-fix.cmd [IGD_DESCRIPTION_URL] [CLIENT_PORT]
REM
REM  Examples:
REM      upnp-fix.cmd
REM      upnp-fix.cmd http://192.168.100.1:49652/49652gatedesc.xml
REM      upnp-fix.cmd "" 30640
REM
REM  NOTE: pure CMD cannot send SSDP multicast (no UDP sockets in cmd), so the
REM  router description URL is either passed as the first argument or taken
REM  from the built-in candidate list below. For fully automatic discovery
REM  use parsec-upnp.ps1 / parsec-upnp.cmd instead.
REM ===========================================================================

if "%~1"=="" goto :start
set "IGD=%~1"
:start
if "%~2"=="" goto :start2
set "CLIENTPORT=%~2"
:start2
if not defined CLIENTPORT set "CLIENTPORT=30640"

set "SOAPFILE=%TEMP%\parsec-upnp-soap.xml"
set "DESCFILE=%TEMP%\parsec-upnp-desc.xml"
set "RESPFILE=%TEMP%\parsec-upnp-resp.xml"

echo ================================================================
echo   Parsec uPnP Fix - CMD edition
echo ================================================================
echo.

where curl >nul 2>&1
if errorlevel 1 (
    echo [FAIL] curl.exe not found. It ships with Windows 10 1803+ and Windows 11.
    goto :end
)

REM --------------------------------------------------------------------------
REM  1. Gateway and local IP from the routing table
REM --------------------------------------------------------------------------
for /f "tokens=1-4" %%a in ('route print -4 2^>nul') do (
    if "%%a"=="0.0.0.0" if "%%b"=="0.0.0.0" (
        set "GW=%%c"
        set "LOCALIP=%%d"
    )
)
if not defined GW (
    echo [FAIL] No default gateway found.
    goto :end
)
echo   Gateway  : !GW!
echo   This PC  : !LOCALIP!
echo   Port     : !CLIENTPORT! ^(client^) + 8000-8010 ^(host^)
echo.

REM --------------------------------------------------------------------------
REM  2. Find the router description URL
REM --------------------------------------------------------------------------
if defined IGD (
    set "DESCURL=!IGD!"
    echo   Using IGD URL from the command line.
    goto :haveurl
)

echo   Looking for the router description...
for %%U in (
    "http://!GW!:49652/49652gatedesc.xml"
    "http://!GW!:5000/rootDesc.xml"
    "http://!GW!:5000/rootdesc.xml"
    "http://!GW!:49152/rootDesc.xml"
    "http://!GW!:1780/rootDesc.xml"
    "http://!GW!:8080/rootDesc.xml"
) do (
    if not defined DESCURL (
        for /f %%S in ('curl -s -m 2 -o NUL -w "%%{http_code}" "%%~U" 2^>nul') do (
            if "%%S"=="200" set "DESCURL=%%~U"
        )
    )
)

if not defined DESCURL (
    echo.
    echo [FAIL] Could not find the router description page by itself.
    echo        Run parsec-upnp.ps1 once - it discovers it over SSDP - or pass
    echo        the URL manually:
    echo            upnp-fix.cmd http://192.168.100.1:PORT/PORTgatedesc.xml
    goto :end
)

:haveurl
echo   Description: !DESCURL!
curl -s -m 5 -o "!DESCFILE!" "!DESCURL!"
if not exist "!DESCFILE!" (
    echo [FAIL] Could not download the description.
    goto :end
)

REM --------------------------------------------------------------------------
REM  3. Locate the WANIPConnection service inside the description
REM --------------------------------------------------------------------------
set "CTRL="
for /f "tokens=2 delims=<>" %%c in ('findstr /I /C:"controlURL" "!DESCFILE!" 2^>nul') do (
    echo %%c | findstr /I /C:"WANIPConn" >nul && set "CTRL=%%c"
    echo %%c | findstr /I /C:"WANPPPConn" >nul && set "CTRL=%%c"
)
if not defined CTRL (
    for /f "tokens=2 delims=<>" %%c in ('findstr /I /C:"controlURL" "!DESCFILE!" 2^>nul') do (
        if not defined CTRL set "CTRL=%%c"
    )
)
if not defined CTRL (
    echo [FAIL] No WANIPConnection control URL found - UPnP may be disabled.
    goto :end
)

if "!CTRL:~0,1!"=="/" (
    set "SVCURL=!CTRL!"
) else (
    set "SVCURL=/!CTRL!"
)
set "REST=!DESCURL:http://=!"
for /f "tokens=1 delims=/" %%h in ("!REST!") do set "HOSTPORT=%%h"
set "CTRLURL=http://!HOSTPORT!!SVCURL!"
set "SVC=urn:schemas-upnp-org:service:WANIPConnection:1"
echo   Control  : !CTRLURL!
echo.

REM --------------------------------------------------------------------------
REM  4. Add the forwardings
REM --------------------------------------------------------------------------
echo   Adding forwardings...
call :addport !CLIENTPORT! Parsec-client
for /l %%p in (8000,1,8010) do call :addport %%p Parsec-host
echo.
echo   Done. Press any key to close.
goto :end

REM --------------------------------------------------------------------------
:addport
(
  echo ^<?xml version="1.0"?^>
  echo ^<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"^>
  echo ^<s:Body^>^<u:AddPortMapping xmlns:u="!SVC!"^>
  echo ^<NewRemoteHost^>^</NewRemoteHost^>
  echo ^<NewExternalPort^>%1^</NewExternalPort^>
  echo ^<NewProtocol^>UDP^</NewProtocol^>
  echo ^<NewInternalPort^>%1^</NewInternalPort^>
  echo ^<NewInternalClient^>!LOCALIP!^</NewInternalClient^>
  echo ^<NewEnabled^>1^</NewEnabled^>
  echo ^<NewPortMappingDescription^>%2^</NewPortMappingDescription^>
  echo ^<NewLeaseDuration^>0^</NewLeaseDuration^>
  echo ^</u:AddPortMapping^>^</s:Body^>^</s:Envelope^>
) > "!SOAPFILE!"

for /f %%S in ('curl -s -m 5 -o "!RESPFILE!" -w "%%{http_code}" -X POST -H "Content-Type: text/xml" -H "SOAPACTION: \"!SVC!#AddPortMapping\"" --data-binary "@!SOAPFILE!" "!CTRLURL!" 2^>nul') do set "HTTP=%%S"

if "!HTTP!"=="200" (
    echo     UDP %1 - added
) else (
    findstr /I /C:"errorCode" "!RESPFILE!" >nul 2>&1 && (
        for /f "tokens=2 delims=>" %%e in ('findstr /I /C:"errorCode" "!RESPFILE!"') do (
            for /f "tokens=1 delims=<" %%n in ("%%e") do set "ECODE=%%n"
        )
        echo     UDP %1 - HTTP !HTTP!, error !ECODE! ^(718 = already exists^)
    ) || (
        echo     UDP %1 - HTTP !HTTP! ^(no response - router may not do UPnP^)
    )
)
exit /b 0

:end
echo.
pause >nul
endlocal
