# Parsec uPnP Fix

Fixes **Parsec error `-6023` / `-11002`** on Windows when the router sits behind a
carrier-grade NAT (CGNAT).

**The classic symptom:** Parsec connects fine from an **Android phone or tablet on
the same Wi-Fi**, but the **Windows PC on that same network cannot connect** — it
just times out with `-6023` while the phone streams without a problem.

---

## Symptoms

### 1. The error banner in the Parsec client

```text
The peer-to-peer network connection between you and the other computer failed [-6023 / -11002]
Something is preventing Parsec from making the connection, check our article for more information.
```

### 2. Client log (`%APPDATA%\Parsec\log_cl.txt`, or Help → Log File)

```text
[D 2026-11-05 19:14:59] Client status changed to: 20
[I 2026-11-05 19:15:00] STUN reply from ::ffff:3.228.228.84:3478
[D 2026-11-05 19:15:09] Client disconnected with status code: -6023 / -11002
[D 2026-11-05 19:15:09] Client status changed to: -3
```

With verbose logging (`app_log_level = 3`) you also see the candidate exchange
completing and then everything going quiet:

```text
[3 19:15:00] CANDEX: WAN ::ffff:<host-public-ip>:21844
[3 19:15:01] Sending Candidate; ::ffff:<your-public-ip>:6153
[3 19:15:01] Sent candidate.
[I 19:15:00] * nat_read_packet[471] = -700000
[I 19:15:09] Client disconnected with status code: -6023 / -11002
```

Both sides exchange candidates successfully — the negotiation is not the problem.

### 3. Host log (on the remote computer)

```text
[I 2026-11-05 19:15:16] <guest>#19688080 failed to connect (-6023 / -11010).
```

Note the **different secondary code on the host side**: `-11010` instead of `-11002`.
Every failing attempt looks like that, while successful ones are just:

```text
[I 2026-11-05 19:28:00] net           = BUD|::ffff:<client-public-ip>|6147
[I 2026-11-05 19:28:00] <guest>#19688080 connected.
```

### 4. The line that names the real cause

```text
UPNP: Getting a valid IGD: A valid connected IGD has been found
but its IP address is reserved (non routable)
```

This is Parsec saying: *"I found your router, but its WAN address is private, so I
am not going to use it."* From that moment on there is no port mapping at all.

---

## What the error codes mean

| Code | Where | Meaning |
|------|-------|---------|
| `-6023` | client | Parsec could not negotiate a peer-to-peer connection |
| `-11002` | client | secondary code: *your ISP uses carrier-grade NAT, or you have multiple routers* |
| `-11010` | host | secondary code: *your router has no UPnP, or UPnP is disabled* |
| `-11013` | host | secondary code: *double NAT — two routers in the path* |

The important bit: `-11002` on the client is **only a description of your network**,
not the cause. The cause is that the router never got a port mapping, so incoming
UDP never reaches the PC.

---

## Root cause

Windows Parsec asks the router for a UPnP port mapping. If the router reports a
**private / non-routable WAN address** (anything in `100.64.0.0/10`, `10/8`,
`172.16/12`, `192.168/16`), Parsec decides the mapping is pointless and silently
skips it.

The Android client does not perform that check and creates the mapping anyway —
which is exactly why the phone works on the same Wi-Fi and the PC does not.

Without the mapping the router has no idea where to deliver the incoming UDP
traffic of the hole-punching attempt, so the connection dies after ~8 seconds.

A packet capture taken during a failed attempt shows it perfectly:

```text
packets sent to the host : 248
packets received         :   0
ICMP                     :   0
```

Packets leave, nothing comes back — because the router dropped them and Parsec
never asked it to open a door.

---

## Quick checks — is this your case?

1. **Android on the same Wi-Fi connects, Windows does not.** ← strongest signal
2. Your public IP is a CGNAT address:
   ```text
   > tracert 1.1.1.1
     1   192.168.100.1
     2   83.x.x.x
     4   100.95.8.3      <- 100.64.0.0/10 = carrier-grade NAT
   ```
   or `curl https://api.ipify.org` returns an address whose reverse DNS says
   `*.cgnat.*`.
3. The router web UI shows a WAN address from the `100.64.0.0/10` range.
4. In the router's UPnP/NAT table there **is** an entry for the Android device but
   **none** for the Windows PC.

If all four match, this script is the fix.

---

## The fix

Create the UPnP forwardings by hand (the router accepts them just fine — it is
Parsec that refuses to ask):

| Protocol | External | Internal          | Purpose              |
|----------|----------|-------------------|----------------------|
| UDP      | 30640    | `<this PC>`:30640 | Parsec client port   |
| UDP      | 8000-8010| `<this PC>`:8000-8010 | Parsec host range |

`parsec-upnp-powershell.ps1` does this automatically:

1. finds the gateway and the local IP from the default route,
2. discovers the router over SSDP (`M-SEARCH` to `239.255.255.250:1900`),
3. walks the UPnP device description to find the `WANIPConnection` service,
4. detects the Parsec client port from `%APPDATA%\Parsec\log_cl.txt`,
5. adds **only the missing** forwardings (existing ones are left alone).

No administrator rights are needed — UPnP IGD is unauthenticated by design.

After the fix the client log bounces straight into a stream:

```text
[D 19:41:32] Client status changed to: 20
[D 19:41:34] net           = BUD|::ffff:<host-public-ip>|38408
[D 19:41:38] decoder       = amd
[D 19:41:38] codec         = h265
```

---

## Requirements

* Windows 10 / 11
* PowerShell 5.1 (built in) or PowerShell 7+
* A router with **UPnP enabled** in its web UI

## Usage

### PowerShell edition (recommended)

```powershell
# create the missing forwardings (default)
.\parsec-upnp-powershell.ps1

# only show what the router currently has
.\parsec-upnp-powershell.ps1 -Mode List

# remove the forwardings created for this PC
.\parsec-upnp-powershell.ps1 -Mode Remove

# custom client port / host range
.\parsec-upnp-powershell.ps1 -ClientPort 30640 -HostRange 8000-8020
```

Or just double-click **`parsec-upnp-launcher.cmd`** — a one-click wrapper that passes any
arguments through.

### CMD edition

**`parsec-upnp-cmdedition.cmd`** does the same job with `cmd.exe` + the built-in `curl.exe` only.
It cannot do SSDP discovery (cmd has no UDP sockets), so it either probes a short
list of common IGD URLs or takes the URL as an argument:

```bat
parsec-upnp-cmdedition.cmd
parsec-upnp-cmdedition.cmd http://192.168.100.1:49652/49652gatedesc.xml
parsec-upnp-cmdedition.cmd "" 30640
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

---

## When to run it again

* after a **router reboot** (static UPnP entries do not always survive),
* after a **Parsec reinstall** or if the client picks a different port,
* whenever `-6023` comes back.

---

## Troubleshooting

| What you see | What it means |
|---|---|
| `No SSDP reply` | UPnP is disabled in the router, or the router is in a different subnet |
| `This router does not expose a WANIPConnection service` | UPnP is on, but the WAN side is not managed by UPnP (bridge / IPoE setups) |
| `UDP xxxxx skipped - already used by <ip>` | another device holds that port; remove the entry or change the port |
| Still `-6023` after the forwardings exist | check that the *host* also has UPnP or port forwarding — `-11010` in its log means it does not |
| Works, but only sometimes | the forwardings are missing/expired; run the script again |

Useful extra data while debugging:

* client log: `%APPDATA%\Parsec\log_cl.txt`
* host log: `%APPDATA%\Parsec\log.txt`
* verbose logs: set `app_log_level = 3` in `%APPDATA%\Parsec\config.json`
* packet capture: `pktmon filter add PeerIP -i <host-ip>` then `pktmon start --capture`

---

## Why not 100% CMD?

Batch has no way to open a UDP socket, so SSDP discovery is impossible in pure
`cmd`. Everything else (HTTP + SOAP) is pure CMD via `curl.exe`, which is why
`parsec-upnp-cmdedition.cmd` exists and works — it just needs the description URL when the
router hides it on a non-standard port.

---

## Cleanup

```powershell
.\parsec-upnp-powershell.ps1 -Mode Remove
```

or remove the entries manually in the router web UI (UPnP / NAT → port forwarding).

---

## Tested with

* Parsec **150-105c** (Windows client and host)
* Huawei HG8245X6-10 router behind a carrier-grade NAT (`100.64.0.0/10` WAN)
* Windows 11

---

## Disclaimer

UPnP IGD has **no authentication** — any device on the local network can ask the
router to open a port. That is how this script works, and it is also why leaving
UPnP enabled on a router is a known security trade-off. Use it on networks you
control.

## License

MIT — see [LICENSE](LICENSE).
