# Taking an EnergoMonitor Homebase off the cloud

What it actually took to make a cloud-only IoT metering gateway report to a local Home
Assistant instead, done on 2026-08-28. Written so it can be repeated — on this device
after a factory reset, or on a similar one.

The device: an EnergoMonitor Homebase `EWGAABBCC` (model EWG6, firmware `31.0-EWG6`) on a
flat `192.168.0.0/24` behind a UniFi Cloud Gateway Ultra, with Home Assistant OS on a
Raspberry Pi 5 at `192.168.0.25`.

## The problem

The Homebase has **no web UI, no configuration interface, and no open TCP ports** — 22,
23, 80, 443, 1883 and 8080 are all closed. It is a pure outbound client. There is nothing
to log into and no setting to change, so "point it at my own server" is not a
configuration task; it has to be done to the device from outside.

Two things made it tractable:

- Its provisioning exchange is **plain HTTP on port 80** — no TLS, so no certificate
  pinning to defeat.
- The vendor's own documentation says the reporting destination *"can be Energomonitor's
  cluster or any server with compatible input API"*. Pointing a Homebase somewhere else is
  a supported deployment, not an attack on it.

## Step 0 — Capture the traffic. Do not skip this.

Everything else depends on knowing exactly what the device says and what the cloud says
back. On the UniFi gateway, as root:

```bash
tcpdump -i any "host 192.168.0.23" -nn -A | tee /tmp/ewg_log.txt
```

Then power-cycle the Homebase. `-A` prints packet payloads as ASCII, which is the whole
point: the provisioning exchange and the MQTT handshake are both readable in the clear.

**This one capture answered five questions that could not have been guessed**, and one of
its answers inverted the plan:

| Question | Answer from the capture |
| --- | --- |
| Device serial | `0123456789ABCDEF`, in the URL path |
| Exact boot response | three CRLF-separated lines, `Content-Length: 69` |
| MQTT credentials | **the device authenticates** — username and password both in the CONNECT packet |
| MQTT topic structure | `sn/<SN>/{status,clock,collector,data}` |
| Generation | EWG6 → firmware over HTTP, so **no TFTP server needed** |

### Reading an MQTT CONNECT out of a hex dump

The credentials were the single most valuable find, and they are recoverable by hand. The
packet body renders as:

```
MQTT......0123456789ABCDEF..sn/0123456789ABCDEF/status..disconnected..0123456789ABCDEF..<REDACTED-16-hex>
```

MQTT 3.1.1 lays out CONNECT as protocol name, level, flags, keepalive, then the payload in
a fixed order: **client ID, will topic, will message, username, password** — each prefixed
with a two-byte length. So the fields fall out in sequence, and the arithmetic confirms
the reading:

```
2 (fixed header) + 10 (variable header)
+ 18 (client id) + 28 (will topic) + 14 (will msg) + 18 (username) + 18 (password)
= 108 bytes = the observed TCP payload length
```

If that sum had not matched, the field boundaries would have been wrong somewhere.

**Consequence:** the local broker never needs anonymous access. The device brings its own
credentials, so you simply teach Mosquitto the ones it already uses, and nothing is opened
up.

## Step 1 — Mosquitto, using the device's own credentials

Install the **Mosquitto broker** add-on. Before starting it, set two logins:

```yaml
logins:
  - username: "0123456789ABCDEF"      # the Homebase, from the capture
    password: "<from the capture>"
  - username: "homeassistant"          # for HA itself
    password: "<long random>"
```

Two traps here:

- **Use `logins:`, not a Home Assistant user account.** The `logins` list writes a
  Mosquitto password file directly, so it is byte-exact and case-sensitive. HA's auth
  provider normalises usernames, and the device sends uppercase hex.
- **Defining `logins:` breaks the MQTT integration's one-click auto-setup.** That flow
  hands HA a Supervisor-generated credential which the password file has never heard of,
  and Mosquitto correctly answers `not authorised`. Choose **"Manually enter the MQTT
  broker connection details"** and use the `homeassistant` login: broker `core-mosquitto`,
  port `1883`.

## Step 2 — Answer the provisioning HTTP on port 80

The Homebase makes two requests to a hardcoded `46.137.108.21:80`, from two different
parts of its own firmware:

```http
GET /api/device/0123456789ABCDEF/upgrade/ HTTP/1.0     -> must be 404, empty
GET /api/device/0123456789ABCDEF/boot/    HTTP/1.0     -> must be 200 + broker address
```

The 404 on `/upgrade/` is what makes the bootloader skip its firmware fetch and carry on.

The 200 body is three lines — primary broker, alternate broker, options:

```
192.168.0.25:1883\r\n192.168.0.25:1883\r\n{"broadcast": 0}
```

### The detail that is easy to get wrong

The captured cloud response declared `Content-Length: 69`, but the three lines are only
**65 characters**. The missing 4 bytes are two `\r\n` pairs — and there is **no trailing
newline**. Serve `\n` line endings and you are two bytes short of the response the device
is known to accept.

So the responder computes `Content-Length` from the encoded bytes, and it deliberately
mirrors the cloud's other quirks rather than tidying them up: `Content-Type: text/html`
for a plain-text body, and `Server: nginx/1.18.0 (Ubuntu)`. The device's HTTP parser is a
black box; the captured response is the only shape known to work.

### Where to run it

On Home Assistant OS there is no user-accessible Docker, so the answer is a **local
add-on** — which *is* a container you write yourself, with Supervisor providing
auto-start, a watchdog, a log viewer and a config UI on top. Four files in
`/addons/energo-boot/`: `config.yaml`, `build.yaml`, `Dockerfile`, `server.py`.

```bash
scp -r addon/energo-boot root@192.168.0.25:/addons/
ssh root@192.168.0.25 'ha store reload'                    # NOT `ha addons reload`
ssh root@192.168.0.25 'ha addons install local_energo_boot'
ssh root@192.168.0.25 'ha addons start   local_energo_boot'
```

**`ha store reload` is the one that matters.** `ha addons reload` reloads *installed*
add-ons; a new folder in `/addons` stays invisible until the **store** is rescanned. It
fails with `does not exist in the store` and logs nothing at all, which makes it look like
a path or naming problem when it is neither.

Verify before touching the router — and use `curl.exe` on Windows, since bare `curl` is a
PowerShell alias for `Invoke-WebRequest`, which takes different flags and throws on a 404:

```bash
curl -i --http1.0 http://192.168.0.25/api/device/0123456789ABCDEF/boot/
#   200, Content-Length: 54, CRLF-separated body
curl -i --http1.0 http://192.168.0.25/api/device/0123456789ABCDEF/upgrade/
#   404, Content-Length: 0
```

## Step 3 — Answer the MQTT handshake

This is the step that is easy not to anticipate. After connecting, the Homebase asks the
server two questions and **publishes nothing at all until both are answered**:

```
device -> sn/<SN>/clock/init      {"version": "0.0"}
server -> sn/<SN>/clock/conf      {"time":1787915015}          (cloud took 640 ms)

device -> sn/<SN>/collector/init  {"version": "5.0"}
server -> sn/<SN>/collector/conf  {"topic":"sn/<SN>/data", ...}  (cloud took 316 ms)
```

Mosquitto is a dumb pipe — it routes messages but never originates one. The vendor's cloud
was not just a data sink, it was an active participant that had to speak first. So
something must stand in for it. Two HA automations are enough; they are the smallest
possible reimplementation of the vendor's server, being two canned replies. See
[`ha-config/automations-energomonitor.yaml`](ha-config/automations-energomonitor.yaml).

Details that matter:

- Match the cloud byte-for-byte, including `{"time":...}` having **no space after the
  colon**, and `qos: 0` / `retain: false`.
- `mode: queued` — the device re-asks, and a reply dropped because the previous run was
  still going costs you a whole cycle.
- MQTT triggers are dead for ~30–60 s during an HA restart. If the device happens to
  handshake in that window it waits for its next cycle. Moving the replies into the add-on
  itself (a small `paho-mqtt` client) removes that gap, at the cost of losing the HA UI and
  automation traces.

A third, temporary automation logs everything on `sn/<SN>/#` into HA's own log under the
logger name `energomonitor.raw`. That single trick is what made decoding the payload
possible — `ha core logs | grep energomonitor.raw` and parse the JSON.

## Step 4 — Get the traffic to the Pi: DNAT **and** SNAT

### A DNS override cannot work

The obvious plan is to override the vendor hostname on the router's DNS. **The capture
disproves it: there is not a single DNS query in it.** The device SYNs straight to the
hardcoded `46.137.108.21` and its `/boot/` request carries `Host: 46.137.108.21`, a literal
IP. The bootloader does send `Host: forerunner.nrgmntr.com`, but to the same hardcoded
address — the hostname is decoration. Only a router DNAT can redirect this.

### Two rules, and the second one is not optional

On UniFi Network 9.x: Settings → Policy Table → Create New Policy → **NAT**.

| | Rule 1 | Rule 2 |
| --- | --- | --- |
| Type | **Dest. NAT** | **Masquerade** |
| Interface | Default (`192.168.0.0/24`) | Default (`192.168.0.0/24`) |
| Protocol | TCP | TCP |
| Source | IP `192.168.0.23`, port **Any** | IP `192.168.0.23`, port **Any** |
| Destination | IP `46.137.108.21`, port `80` | IP `192.168.0.25`, port `80` |
| Translated | `192.168.0.25` | — |

Then **Reorder** both above the two default `Translate Network …` masquerade rules.

**Why rule 2 exists.** The Homebase (`.23`) and the Pi (`.25`) are on the same flat `/24`.
With DNAT alone, the Pi answers `.23` directly over layer 2 with source `192.168.0.25`,
never passing back through the router to be un-NATed. The device is waiting to hear from
`46.137.108.21`, receives a packet from a stranger, and resets the connection. Rule 1 will
look perfectly configured and nothing will work. Masquerading forces the reply back
through the router, which is the only place that remembers the translation.

Same-subnet DNAT is the one case where the return path does not take care of itself.

**Do not pin a source port.** The device uses a fresh ephemeral port every time — the
capture shows `49451`, `49356`, `49165`, `49219`, `49351` across five connections. A rule
pinned to one source port never matches a single packet, silently.

**Telling the two failure modes apart:** watch the add-on log while power-cycling the
Homebase. No requests at all → rule 1 is not matching. Requests arrive but the device keeps
retrying → rule 2 is missing. With masquerade working the log shows the *router's* IP as
the client, not `.23` — that is correct, not a fault.

Not sure the UI is expressing what you meant? Prove it with iptables on the gateway first
(temporary, gone on reboot), then go find the right UI construct knowing what success
looks like:

```bash
iptables -t nat -A PREROUTING  -i br0 -p tcp -d 46.137.108.21 --dport 80 -j DNAT --to-destination 192.168.0.25:80
iptables -t nat -A POSTROUTING -o br0 -p tcp -d 192.168.0.25  --dport 80 -j MASQUERADE
```

## Step 5 — Decode the measurements

The payload is **not** the format in the vendor's public forwarder documentation. It is far
more compact, and it is one object per message rather than an array:

```json
{"t":1787937872,"f":5,"u":"01000001","d":1,"ch":0,"e":10,"v":0,
 "s":[{"m":15,"v":[20675]},{"m":25,"v":[10000]},{"m":12,"v":[685]},
      {"m":10,"v":[50]},{"m":11,"v":[-46]}]}
```

`t` epoch · `f` format version · `u` sensor serial · `d` hardware type · `ch` channel ·
`e` sequence counter (wraps 0–15) · `v` unknown, always 0 · `s` measurements, keyed by
medium code `m`.

### How the medium codes were identified

Ranges alone are not enough — they produce plausible-looking wrong answers. Three
techniques did the work:

**Monotonicity.** `m=15` never decreased across 56 samples. A rate wobbles both ways; only
a cumulative counter climbs monotonically. That identified it as a counter and made
`state_class: total_increasing` the right choice.

**Cross-checking two fields against each other.** This is the one that produced certainty.
If `m=15` is a pulse count and `m=25` is the meter constant, then the counter's rate must
independently reproduce `m=12`:

| Δ pulses over 10 s | Implied power from the counter | `m=12` |
| --- | --- | --- |
| +19 | 684 W | **685 W** |
| +19 | 684 W | **701 W** |
| +28 | 2016 W | **2003 W** |

Agreement inside 1% per interval, 94.3% over a 100 s window. That settles all three codes
at once — and no single-field analysis could have.

**Comparing the same code across different sensor types.** `m=10` reads 46–51 on *every*
sensor including both meters. It cannot be humidity: three sensors in different rooms would
not agree within 2% while their temperatures differ, and a gas meter would not report it.
Still unidentified — link quality or battery.

### The mistake this avoided repeating

An earlier pass concluded `m=15` was watt-hours, from a meter whose `m=25` was 100. The
arithmetic fitted by coincidence. The second meter's constant of 10000 exposed it: **the
unit only exists after dividing by the meter constant.**

```
electricity kWh = m15 / m25      (10000 imp/kWh)
gas         m³  = m15 / m25      (100 imp/m³ — the reed contact on the 0.01 m³ digit)
```

### Key entities in `ha-config/mqtt.yaml`

| Entity | From | Feeds |
| --- | --- | --- |
| electricity energy, kWh | `m15 / m25` | Energy dashboard → grid consumption |
| electricity power, W | `m12` | live power |
| gas, m³ | `m15 / m25` | Energy dashboard → gas consumption |
| temperature °C × 3 | `m16` | — |
| RSSI dBm, raw `m10`, meter constant | `m11`, `m10`, `m25` | diagnostics |

### Key on the serial, never the channel

Channels are slot assignments the Homebase reshuffles when reconfigured — reconfiguring
swapped the electricity and gas meters between channels 0 and 1. Serials are burned into
the sensors. Had the entities filtered on `ch == 0`, that swap would have silently
redirected gas readings into the electricity entity and vice versa: no error, no warning,
two graphs quietly telling lies.

Identity comes from the thing itself, never from the position it occupies.

## Order of operations

Bring-up order matters, because a handshake missed while something is not yet listening
costs a whole device cycle:

1. Mosquitto running, with both logins
2. MQTT integration connected (manual, not auto-setup)
3. Handshake automations loaded — Developer Tools → YAML → Reload Automations
4. Boot responder add-on installed and answering on `:80`
5. Router NAT rules in place
6. **Then** power-cycle the Homebase

## Verification

| Check | Expected |
| --- | --- |
| `curl -i --http1.0 …/boot/` | 200, `Content-Length: 54`, CRLF body |
| `curl -i --http1.0 …/upgrade/` | 404, `Content-Length: 0` |
| Add-on log during a power-cycle | requests from `192.168.0.1` (masquerade) or `.23` |
| Mosquitto log | `New client connected … as 0123456789ABCDEF (p4, c1, k15, u'0123456789ABCDEF')` |
| MQTT → Listen to topic `sn/<SN>/#` | `status=connected`, then `clock/init`, `collector/init`, then `data` |
| Pull the Homebase's power | entities go `unavailable` via its last-will message |

And the one that proves the actual goal, on the gateway:

```bash
tcpdump -i any host 192.168.0.23 and not net 192.168.0.0/24
```

Silence means the Homebase never talks to the internet again.

## Still open

- **`m=10`** — 46–51 everywhere; not humidity, not a clean function of RSSI. Breathe on a
  temperature sensor with the MQTT listener open to rule humidity in or out.
- **`m=13`** — on the gas sensor only, reads 6–8 while no gas flows, so not a flow rate.
- **`sn/<SN>/cmd/init`** = `{"version":"1.0","device_id":13,"interface_version":4}` is
  published and **never answered** — it does not appear in the original capture. Harmless
  so far, but `cmd` is the obvious channel for configuring paired meters.
- **Optional hardening:** an ACL limiting the Homebase login to `sn/<SN>/#`. Its credential
  crosses the LAN in cleartext on every session and cannot be changed, so restricting what
  it may publish matters far more than password strength — as things stand it could publish
  to `homeassistant/sensor/.../config` and create arbitrary HA entities. Read the add-on's
  shipped `mosquitto.conf` first: a global `acl_file` that does not also grant HA full
  access will break HA's own connection.

## A note on the credential

The Homebase's MQTT password was recovered from the capture. It lives in the Mosquitto
add-on options on the Pi and **nowhere else** — not in this repo, not in these docs. The
original capture file contains it in cleartext, so keep that out of the workspace too.

## References

- Serials here are placeholders: `0123456789ABCDEF` for the Homebase,
  `01000001` / `02000002` / `08000001`-`3` for the sensors. The vendor IPs and
  hostnames are real.
- [Homebase docs](https://developers.energomonitor.com/partners/homebase/) ·
  [Provisioning API](https://developers.energomonitor.com/partners/provisioning/homebase/) ·
  [Forwarder](https://developers.energomonitor.com/partners/forwarder/) ·
  [Data format](https://developers.energomonitor.com/partners/forwarder/format/)
