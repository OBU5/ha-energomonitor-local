#!/usr/bin/env python3
"""Local provisioning responder for the EnergoMonitor Homebase (EWG6).

Stands in for the vendor's cloud endpoint (46.137.108.21:80) so the Homebase is told
to report to a local MQTT broker instead of the internet.

Every status code, header and byte below mirrors a real exchange captured with tcpdump
on 2026-08-28 (see ha-tools/docs/energomonitor-local-server.md).  That includes quirks
we would not choose ourselves - the plain-text body is served as text/html, and the
server identifies itself as nginx - because the device's HTTP parser is a black box and
the captured response is the only shape known to work.  Do not "clean these up".

Two endpoints matter:

  GET /api/device/<SN>/upgrade/   -> 404, empty.  Makes the bootloader skip the
                                    firmware fetch.  This is why no TFTP server is
                                    needed: EWG6 does firmware over HTTP.
  GET /api/device/<SN>/boot/      -> 200, three CRLF-separated lines telling the
                                    device which MQTT broker to use.

Anything else is answered 404 and logged in full, so an endpoint the capture never
showed becomes visible instead of silently failing.
"""

import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OPTIONS_PATH = "/data/options.json"

DEFAULTS = {
    "device_sn": "0123456789ABCDEF",
    "mqtt_host": "192.168.0.25",
    "mqtt_port": 1883,
    "broadcast": 0,
    "crlf": True,
    "trailing_newline": False,
}

# Mirrored from the captured cloud response so the device sees an unchanged signature.
SERVER_HEADER = "nginx/1.18.0 (Ubuntu)"
ALLOW_HEADER = "GET, HEAD, OPTIONS"

# /api/device/<16 hex chars>/<boot|upgrade>/
PATH_RE = re.compile(r"^/api/device/([0-9A-Fa-f]{16})/(boot|upgrade)/$")


def log(message):
    """Timestamped line to stdout, which is the Supervisor add-on log."""
    sys.stdout.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))
    sys.stdout.flush()


def load_options():
    """Supervisor writes the add-on options to /data/options.json."""
    opts = dict(DEFAULTS)
    try:
        with open(OPTIONS_PATH, "r", encoding="utf-8") as handle:
            opts.update(json.load(handle))
        log("options loaded from %s" % OPTIONS_PATH)
    except FileNotFoundError:
        log("no %s - using defaults (local test mode)" % OPTIONS_PATH)
    except (OSError, ValueError) as err:
        log("!! cannot read %s (%s) - using defaults" % (OPTIONS_PATH, err))

    for key in ("mqtt_port", "broadcast"):
        opts[key] = int(opts[key])
    for key in ("crlf", "trailing_newline"):
        opts[key] = bool(opts[key])
    return opts


def build_boot_body(opts):
    """The /boot/ response body, as raw bytes.

    Line 1 is the primary broker, line 2 the alternate - the cloud sent an IP and a
    hostname; we send the same local address twice.  Line 3 is the broadcast flag.

    Line endings are CRLF: the captured response declared Content-Length 69 for
    19 + 30 + 16 = 65 characters of text, and the missing 4 bytes are two CRLF pairs.
    There is no trailing terminator.
    """
    eol = "\r\n" if opts["crlf"] else "\n"
    endpoint = "%s:%d" % (opts["mqtt_host"], opts["mqtt_port"])
    body = eol.join([endpoint, endpoint, '{"broadcast": %d}' % opts["broadcast"]])
    if opts["trailing_newline"]:
        body += eol
    return body.encode("utf-8")


class BootHandler(BaseHTTPRequestHandler):
    # The device speaks HTTP/1.0; the cloud answered HTTP/1.1 with Connection: close.
    protocol_version = "HTTP/1.1"
    server_version = SERVER_HEADER
    sys_version = ""

    options = DEFAULTS  # replaced with the loaded options at startup

    def version_string(self):
        # The base class returns "<server_version> <sys_version>", which leaves a
        # trailing space when sys_version is empty.  The captured cloud header had
        # none, so emit it verbatim.
        return SERVER_HEADER

    def log_message(self, fmt, *args):
        log("%s %s" % (self.client_address[0], fmt % args))

    def _respond(self, status, body=b"", content_type=None):
        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.send_header("Allow", ALLOW_HEADER)
        # Present in the captured response.  Meaningless to the device, kept so the
        # reply differs from the proven-good one in as few ways as possible.
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Vary", "Cookie")
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def _log_request_detail(self, note):
        detail = ["%s -- %s %s %s" % (note, self.command, self.path,
                                      self.request_version)]
        for name, value in self.headers.items():
            detail.append("    %s: %s" % (name, value))
        length = self.headers.get("Content-Length")
        if length and length.isdigit() and int(length) > 0:
            payload = self.rfile.read(int(length))
            detail.append("    body: %r" % payload)
        log("\n".join(detail))

    def _handle(self):
        match = PATH_RE.match(self.path)
        if not match:
            self._log_request_detail("!! UNKNOWN ENDPOINT")
            self._respond(404)
            return

        serial, endpoint = match.group(1), match.group(2)
        configured = str(self.options["device_sn"])
        if serial.upper() != configured.upper():
            log("!! serial %s is not the configured %s - answering anyway"
                % (serial, configured))

        if endpoint == "upgrade":
            log("%s %s upgrade/ -> 404, no firmware offered" % (self.command, serial))
            self._respond(404)
            return

        body = build_boot_body(self.options)
        log("%s %s boot/    -> 200, Content-Length %d, body %r"
            % (self.command, serial, len(body), body))
        self._respond(200, body, "text/html; charset=utf-8")

    do_GET = _handle
    do_HEAD = _handle

    def do_OPTIONS(self):
        self._respond(200)


def main():
    opts = load_options()
    BootHandler.options = opts

    port = int(os.environ.get("ENERGO_LISTEN_PORT", "80"))
    body = build_boot_body(opts)
    log("EnergoMonitor boot responder starting on 0.0.0.0:%d" % port)
    log("serial %s, broker %s:%d, broadcast %d"
        % (opts["device_sn"], opts["mqtt_host"], opts["mqtt_port"], opts["broadcast"]))
    log("boot body is %d bytes: %r" % (len(body), body))

    server = ThreadingHTTPServer(("0.0.0.0", port), BootHandler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
