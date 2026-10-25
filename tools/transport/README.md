# Transport test tools

Replays real video frame sizes over TCP, UDP or QUIC between two Macs and measures what a receiver would see: frame latency, lost frames, and hitches. The tools produced [research/transport-2026-09-30](../../research/transport-2026-09-30/README.md).

| Tool | What it does |
|---|---|
| `nettest.swift` | `trace`: hardware-encodes synthetic scrolling text with the app's encoder settings and writes one frame size per line. `recv`: the receiver, listening on all transports. `send <host> <mode> <trace>`: replays a trace. Modes: `tcp`, `quic1`, `quicN`, `udp`, `udpnack`, `qdgram`, `qdgramnack`. Options: `pace=<Mbps>`, `inflight=<n>`, `svc=video\|responsive\|signaling`. |
| `build.sh` | Builds for both Macs, makes a throwaway TLS identity for QUIC, and copies everything to `/tmp/nettest` on the receiver (`OD_RECEIVER_HOST`, default `imac`). |
| `matrix.sh <host> <link> <rounds> <secs> <trace...>` | Runs every mode interleaved and appends JSON results (`MODES`, `OUT`, and `LOAD=1` as a label for runs with a bulk copy alongside). |
| `agg.py`, `fmt.py` | Summarise results across rounds, or one line per run. |
| `probe.py` | A 200 Hz UDP echo that shows how often a link stalls and at what spacing. It found the AirDrop "Everyone" stalls. |

The receiver's QUIC listener imports the identity into a temporary file keychain, because over ssh the login keychain is locked. The traffic is random bytes, so runs never carry anything from your screen.


### Interactive fork: repeatable animation

`animation.swift` creates a temporary, mouse-transparent window on a named
auxiliary display, scrolls text and moves a shape at a 60 Hz timer cadence,
then closes automatically. It refuses the primary screen. It supplies a
repeatable source workload; its draw count is not a receiver FPS measurement.

```sh
swiftc -parse-as-library tools/transport/animation.swift -o /tmp/od-animation
/tmp/od-animation 'OpenDisplay — iPhone Dev' 25
```

For this fork's Fast/WiFi mode, the sender log identifies `videoTransport`
(`udp` or compatibility `tcp`), receipt RTT/window, target bitrate, expired
frames and receiver stale/decode skips. The capability is negotiated with the
Debug iOS receiver (TCP 9100 / UDP 9101). See PROTOCOL.md 6.8–6.9.
A Debug-only `disableVideoDatagrams` UserDefaults boolean can force receipt-
bounded TCP for comparisons; set it before connecting, and remove it before
normal UDP testing. Keep workload, display orientation and receiver mode fixed
when comparing. Delivered-frame latency alone excludes skipped frames, so
always inspect FPS, frame gaps and drop/recovery counters as well.
