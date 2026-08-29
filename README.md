# EnergoMonitor Homebase - local integration

Makes the EnergoMonitor Homebase gateway `EWGAABBCC` report to the local Home Assistant
install instead of the vendor cloud, with no internet dependency and no inbound
port-forward. Working since 2026-08-28.

The protocol was reverse-engineered from a `tcpdump` capture of the real cloud exchange.

**[`HOWTO.md`](HOWTO.md) is the main document** - what it took, step by step, every trap,
and the wire-level protocol detail.

> Serials in this repo are placeholders. The Homebase serial appears as
> `0123456789ABCDEF` and the sensor serials as `01000001` / `02000002` / `08000001`-`3`.
> Substitute your own - the first byte of a sensor serial encodes its hardware type, so
> keep that byte if you invent placeholders of your own.

## The two "gateways"

| Term | What | IP |
| --- | --- | --- |
| **Homebase** | The EnergoMonitor device (`EWG` is their gateway family name) | `192.168.0.23` |
| **UCG-Ultra** | The UniFi router, where the NAT rules live | `192.168.0.1` |

## How it works

```
Homebase .23 --HTTP :80 to 46.137.108.21--> UCG-Ultra .1   DNAT + SNAT
                                                 |
                                                 v
                                           Pi .25:80   energo-boot add-on
                                                       "use 192.168.0.25:1883"

Homebase .23 --MQTT :1883 to 192.168.0.25--------------> Pi .25:1883  Mosquitto
                 |__ same subnet, router not involved __|        |
                                                          HA automations
                                                          answer the handshake
```

Three pieces, all necessary:

1. **`addon/energo-boot/`** answers the provisioning HTTP. The Homebase asks
   `/api/device/<SN>/upgrade/` (must be `404`, which makes it skip the firmware fetch)
   and `/api/device/<SN>/boot/` (must be `200` with the broker address).
2. **Mosquitto** with the Homebase's own captured credentials. The device authenticates
   as `0123456789ABCDEF`, so the broker stays locked down - no anonymous access.
3. **`ha-config/automations-energomonitor.yaml`** answers the MQTT handshake. The
   Homebase publishes `clock/init` and `collector/init` and will not send a single
   measurement until both are answered. Mosquitto is a dumb pipe that never originates a
   message - something has to speak for the vanished cloud, and this is it.

## Layout

| Path | Lines | Deploys to |
| --- | --- | --- |
| `addon/energo-boot/server.py` | 189 | the only executable code |
| `addon/energo-boot/config.yaml` | 31 | Supervisor add-on manifest |
| `addon/energo-boot/Dockerfile` | 11 | container build |
| `addon/energo-boot/build.yaml` | 2 | base image pin |
| `ha-config/automations-energomonitor.yaml` | 65 | `/config/automations.yaml` |
| `ha-config/mqtt.yaml` | 489 | `/config/mqtt.yaml` |

Everything except `server.py` is declarative - Supervisor metadata or data that Home
Assistant interprets. There is one program in this project.

---

## The code

### `server.py`

A single-purpose HTTP server impersonating the vendor's provisioning endpoint. Five
parts:

**`load_options()`** reads `/data/options.json`. That path is the Supervisor contract:
whatever is set in the add-on's Configuration tab is written there as JSON before the
container starts. If the file is absent it falls back to `DEFAULTS`, which is what lets
the same file run on a laptop for testing.

**`build_boot_body()`** builds the `/boot/` body and returns **bytes, not a string**, so
that `Content-Length` is computed from encoded bytes rather than character count. That is
exactly the trap the capture exposed - `Content-Length: 69` against 65 characters of
text, the difference being two CRLF pairs.

```python
eol = "\r\n" if opts["crlf"] else "\n"
body = eol.join([endpoint, endpoint, '{"broadcast": %d}' % opts["broadcast"]])
```

`crlf` and `trailing_newline` are add-on options, so line-ending behaviour is a config
toggle rather than a rebuild if the device turns out fussier than the capture suggests.

**`_respond()`** emits the captured header set, `X-Frame-Options` and `Vary: Cookie`
included. Those are meaningless to the device; they are there so the reply differs from
the proven-good one in as few ways as possible.

**`_handle()`** routes on one regex:

```python
PATH_RE = re.compile(r"^/api/device/([0-9A-Fa-f]{16})/(boot|upgrade)/$")
```

`upgrade` → 404, `boot` → 200 plus body, anything else → 404 plus a full dump of method,
path, headers and body.

**`main()`** runs a `ThreadingHTTPServer` on `0.0.0.0:80`, with `ENERGO_LISTEN_PORT` as
an environment override so it can be tested on a high port without root.

### Three decisions that look odd and are not

**The regex accepts *any* 16-hex serial**, then logs a warning if it is not the
configured one, rather than rejecting it. A strict match would make a second gateway - or
a serial mistyped in the options - look identical to a dead network. A warning in the log
makes it obvious.

**Unknown paths are logged in full.** A capture is a sample, not a specification. If the
device ever asks for an endpoint the capture never showed, it appears in the log complete
with headers instead of failing silently. That tripwire is what later caught `cmd/init`,
albeit on the MQTT side.

**`version_string()` is overridden for one character.** Python's base class returns
`server_version + " " + sys_version`, leaving a trailing space when `sys_version` is
empty; the cloud's header had none. It cannot matter - but the design rule is "differ
from the proven response in as few ways as possible", and once that rule admits
exceptions you can no longer say what has actually been tested.

### `Dockerfile`

Alpine base, `apk add python3`, then:

```dockerfile
CMD ["python3", "-u", "/server.py"]
```

**The `-u` is load-bearing.** Without unbuffered stdout the Supervisor add-on log stays
empty until the buffer flushes, which makes debugging the handshake miserable.

### `config.yaml`

Slug `energo_boot` (Supervisor addresses it as `local_energo_boot`), `ports: {80/tcp: 80}`
to map container port 80 onto the host, `boot: auto`, a TCP watchdog, and the schema for
the options that arrive in `/data/options.json`.

### `mqtt.yaml`

Long because each of the 21 entities repeats the same ~12 lines with two literals changed
- the sensor serial and the medium code. The only real logic is the Jinja in
`value_template`, which filters one sensor out of a shared topic:

```jinja
{%- if value_json.u == '01000001' -%}
{%- set p = value_json.s | selectattr('m', 'eq', 15) | list -%}
{{ p[0].v[0] if p else this.state }}
{%- else -%}
{{ this.state }}
{%- endif -%}
```

The `this.state` fallback is what stops an entity flipping to `unknown` every time a
message arrives that belongs to a different sensor.

---

## Things that will bite

**Protocol**

- **A DNS override cannot work.** The Homebase has `46.137.108.21` hardcoded and makes no
  DNS query at all - there is not one in the capture, and `/boot/` sends
  `Host: 46.137.108.21`. Only a router DNAT can redirect it.
- **DNAT alone is not enough.** The Homebase (`.23`) and the Pi (`.25`) are on one flat
  `/24`. With DNAT only, the Pi replies straight to `.23` over layer 2 with source
  `192.168.0.25`, never passing back through the router to be un-NATed; the Homebase is
  waiting for `46.137.108.21`, sees a stranger and sends RST. A **SNAT/masquerade rule is
  mandatory**, and its absence looks exactly like a working configuration.
- **Do not pin a source port** in either NAT rule. The device uses a fresh ephemeral port
  each connection (`49451`, `49356`, `49165`, …); a pinned rule never matches, silently.
- **The boot body uses CRLF with no trailing newline.** See `build_boot_body()`.
- **Do not "clean up" `server.py`'s headers.** It serves a plain-text body as `text/html`
  and claims to be nginx because that is what the device was observed to accept.

**Home Assistant**

- **`ha store reload`, not `ha addons reload`.** The latter reloads *installed* add-ons; a
  new folder in `/addons` stays invisible until the **store** is rescanned. It fails with
  `does not exist in the store` and logs nothing at all.
- **Defining `logins:` in Mosquitto breaks the MQTT integration's auto-setup.** That flow
  hands HA a Supervisor-generated credential the password file has never heard of, and the
  broker answers `not authorised`. Use *"Manually enter the MQTT broker connection
  details"*.
- **`name:` must carry only the entity-specific part.** Since HA 2023.8 an MQTT entity
  belonging to a device gets the device name prefixed automatically. Repeating it produces
  `sensor.energomonitor_electricity_energomonitor_electricity_energy`, and `entity_id` is
  assigned once and then sticky - fixing the name later does not rename it.
- **Key entities on `u` (serial), never on `ch`.** Channels are slot assignments the
  Homebase reshuffles on reconfiguration; on 2026-08-28 the electricity and gas meters
  swapped between channels 0 and 1. Keying on channel would have silently redirected gas
  readings into the electricity entity - no error, two graphs quietly telling lies.

**Secrets**

- **Never commit the MQTT password.** The Homebase authenticates with a credential
  recovered from the capture; it belongs in the Mosquitto add-on options on the Pi and
  nowhere else. The original capture file contains it in cleartext - keep that out of the
  workspace too.

## Placeholders and `local/`

The YAML here carries **placeholder serials** so the repo can be public. They are mapped
back to a real device by `local/substitutions.sed`, which is gitignored:

```bash
cp substitutions.sed.example local/substitutions.sed
$EDITOR local/substitutions.sed      # fill in your own serials
```

Sensor serials keep their first byte, because that byte encodes the hardware type
(`01` electricity, `02` gas, `08` temperature). See `local/README.md`, including how to
recover the real values from a running installation if that file is ever lost.

## Deploy

```bash
./deploy.sh --render      # render to build/, copy nothing - inspect it first
./deploy.sh               # render, back up on the Pi, copy, run `ha core check`
```

`deploy.sh` refuses to copy anything if a placeholder survives rendering, so a missing
mapping fails loudly instead of silently deploying a broken config.

Override the target with `HA_HOST`, `HA_USER`, `HA_KEY`.

The add-on is deployed separately, since it changes rarely:

```bash
KEY=~/.ssh/private-key_HomeAssistant_ed25519
scp -i $KEY -r addon/energo-boot root@192.168.0.25:/addons/
ssh -i $KEY root@192.168.0.25 'ha store reload'
ssh -i $KEY root@192.168.0.25 'ha addons install local_energo_boot'
ssh -i $KEY root@192.168.0.25 'ha addons start   local_energo_boot'
```

`configuration.yaml` needs one line, once:

```yaml
mqtt: !include mqtt.yaml
```

Then in the HA UI: enable **Watchdog** on the add-on, and reload via
Developer Tools → YAML → *Reload Automations* and *Manually configured MQTT entities*.

## Adding a sensor

A new sensor appears in the MQTT stream on its own, but does not become an entity by
itself - the entity list is explicit. To add one:

1. Find its serial: **MQTT → Configure → Listen to a topic** on `sn/<SN>/#`, and watch for
   a `u` you do not recognise. Its `m` codes tell you what it measures.
2. Copy an existing entity block in `ha-config/mqtt.yaml`, change the `u` filter to a
   **new placeholder** keeping the hardware-type first byte, and change the `m` code.
3. Add the mapping line to `local/substitutions.sed`.
4. `./deploy.sh`, then reload MQTT entities.

Do **not** key an entity on `ch` - see *Things that will bite*.

Bring-up order matters - a handshake missed while something is not yet listening costs a
whole device cycle: Mosquitto → MQTT integration → automations → responder → NAT rules →
**then** power-cycle the Homebase.

## Verify

```bash
curl -i --http1.0 http://192.168.0.25/api/device/0123456789ABCDEF/boot/
#   200, Content-Length: 54, CRLF-separated body
curl -i --http1.0 http://192.168.0.25/api/device/0123456789ABCDEF/upgrade/
#   404, Content-Length: 0
```

On Windows use `curl.exe` - bare `curl` is a PowerShell alias for `Invoke-WebRequest`,
which takes different flags and throws on a 404.

Then power-cycle the Homebase and watch both logs: the add-on log in the HA UI, and the
core log via `ha-tools\ha-connect.ps1 -Logs -Follow`. Requests arriving from
`192.168.0.1` rather than `.23` are correct - that is the masquerade.

The check that proves the actual goal, on the UCG-Ultra:

```bash
tcpdump -i any host 192.168.0.23 and not net 192.168.0.0/24
# silence = the Homebase is fully local
```
