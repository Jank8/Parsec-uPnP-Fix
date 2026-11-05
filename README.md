# Parsec uPnP Fix

Fixes **Parsec error `-6023` / `-11002`** on Windows when the router sits behind a
carrier-grade NAT (CGNAT).

If Parsec connects fine from an **Android device on the same Wi-Fi** but not from
your **Windows PC**, this is almost certainly the cause.

---

## The problem

Windows Parsec asks the router for a UPnP port mapping. If the router reports a
**private / non-routable WAN address** (anything in `100.64.0.0/10`, `10/8`,
`172.16/12`, `192.168/16`), Parsec decides the mapping is pointless and silently
skips it. You can see this in the client log:

```
UPNP: Getting a valid IGD: A valid connected IGD has been found
      but its IP address is reserved (non routable)
```

The Android client does not perform that check and creates the mapping anyway —
which is exactly why the phone works and the PC does not.

Without the mapping the router does not know where to deliver the incoming UDP
traffic of the hole-punching attempt, so the connection dies after ~8 seconds:

```
client:  Client disconnected with status code: -6023 / -11002
host:    <guest> failed to connect (-6023 / -11010)
```

A packet capture during the failed attempt looks like this — packets leave, nothing
comes back:

```
packets sent to the host : 248
packets received         :   0
```

## The fix

Create the UPnP forwardings by hand (the router accepts them just fine — it is
Parsec that refuses to ask):

| Protocol | External | Internal          | Purpose              |
|----------|----------|-------------------|----------------------|
| UDP      | 30640    | `<this PC>`:30640 | Parsec client port   |
| UDP      | 8000-8010| `<this PC>`:8000-8010 | Parsec host range |

`parsec-upnp.ps1` does this automatically:

1. finds the gateway and the local IP from the default route,
2. discovers the router over SSDP (`M-SEARCH` to `239.255.255.250:1900`),
3. walks the UPnP device description to find the `WANIPConnection` service,
4. detects the Parsec client port from `%APPDATA%\Parsec\log_cl.txt`,
5. adds **only the missing** forwardings (existing ones are left alone).

No administrator rights are needed — UPnP IGD is unauthenticated by design.

## Requirements

* Windows 10 / 11
* PowerShell 5.1 (built in) or PowerShell 7+
* A router with **UPnP enabled** in its web UI

## Usage

### PowerShell edition (recommended)

```powershell
# create the missing forwardings (default)
.\parsec-upnp.ps1

# only show what the router currently has
.\parsec-upnp.ps1 -Mode List

# remove the forwardings created for this PC
.\parsec-upnp.ps1 -Mode Remove

# custom client port / host range
.\parsec-upnp.ps1 -ClientPort 30640 -HostRange 8000-8020
```

Or just double-click **`parsec-upnp.cmd`** — it is a one-click wrapper that passes
any arguments through.

### CMD edition

**`upnp-fix.cmd`** does the same job with `cmd.exe` + the built-in `curl.exe` only.
It cannot do SSDP discovery (cmd has no UDP sockets), so it either probes a short
list of common IGD URLs or takes the URL as an argument:

```bat
upnp-fix.cmd
upnp-fix.cmd http://192.168.100.1:49652/49652gatedesc.xml
upnp-fix.cmd "" 30640
```

The CMD edition always re-adds all forwardings (most routers treat an identical
mapping as a no-op), while the PowerShell edition only adds what is missing.

### Typical output

```
[1/5] Detecting the local network...
  Interface : Wi-Fi
  This PC   : 192.168.100.3
  Router    : 192.168.100.1

[2/5] Looking for the router over SSDP...
  Description: http://192.168.100.1:49652/49652gatedesc.xml

[3/5] Reading the device description...
  Service    : http://192.168.100.1:49652/upnp/control/WANIPConn1

[4/5] Resolving the Parsec client port...
  Detected from the Parsec log: 30640

[5/5] Forwardings currently on the router:
  UDP  30640  -> 192.168.100.3:30640   [Parsec-client]  <-- this PC
  ...
  Router WAN address: 100.112.235.38
  Note: that is a private/CGNAT address - this is exactly the case
  where Parsec skips UPnP on its own. The forwardings below are the fix.

Adding missing forwardings...
  UDP 30640  added (Parsec-client)
  ...

Done: 12 added, 0 already present, 0 failed.
```

## When to run it again

* after a **router reboot** (static UPnP entries do not always survive),
* after a **Parsec reinstall** or if the client picks a different port,
* whenever `-6023` comes back.

## Why not 100% CMD?

Batch has no way to open a UDP socket, so SSDP discovery is impossible in pure
`cmd`. Everything else (HTTP + SOAP) is pure CMD via `curl.exe`, which is why
`upnp-fix.cmd` exists and works — it just needs the description URL when the
router hides it on a non-standard port.

## Cleanup

```powershell
.\parsec-upnp.ps1 -Mode Remove
```

or remove the entries manually in the router web UI (UPnP / NAT → port forwarding).

## Tested with

* Parsec **150-105c** (Windows client and host)
* Huawei HG8245X6-10 router behind a carrier-grade NAT (`100.64.0.0/10` WAN)
* Windows 11

## Disclaimer

UPnP IGD has **no authentication** — any device on the local network can ask the
router to open a port. That is how this script works, and it is also why leaving
UPnP enabled on a router is a known security trade-off. Use it on networks you
control.

## License

MIT — see [LICENSE](LICENSE).
