#!/usr/bin/env python3
"""
Minimal HTTP → GSS-TSIG nsupdate for dhcp-triggered DDNS (Samba AD BIND DLZ).

POST /ddns/v1/lease  JSON {"action":"upsert"|"delete","address":"...","hostname":"label","client_id":"..."}
  IPv4 delete: hostname may be empty — PTR for the address is always removed; A is removed if hostname is set
  or if a single-label name in DNS_ZONE is inferred from PTR (dig -x).
GET  /ddns/v1/health
"""
from __future__ import annotations

import fcntl
import ipaddress
import json
import logging
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

LOG = logging.getLogger("ddns-nsupdate")

_LOCK_PATH = os.environ.get("DDNS_LOCK_PATH", "/tmp/ddns-nsupdate.lock")
_MAX_BODY = 8192

_HOSTNAME_LABEL = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")


def _env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None or v == "":
        raise RuntimeError(f"missing required env {name}")
    return v


class Config:
    def __init__(self) -> None:
        self.shared_secret = _env("DDNS_SHARED_SECRET")
        self.krb_kt = _env("KRB5_KTNAME", "/keytab/dnsupdater.keytab")
        self.krb_principal = _env("KRB_PRINCIPAL")
        self.dns_zone = _env("DNS_ZONE", "home.2123studios.com")
        self.krb_realm = _env("KRB_REALM", "HOME.2123STUDIOS.COM")
        self.nsupdate_server = _env("NSUPDATE_SERVER", "127.0.0.1")
        self.dns_port = os.environ.get("DNS_PORT", "53")
        self.ttl = os.environ.get("DNS_RECORD_TTL", "3600")
        self.listen_addr = os.environ.get("DDNS_LISTEN_ADDR", "127.0.0.1")
        self.listen_port = int(os.environ.get("DDNS_LISTEN_PORT", "8765"))


CFG = Config()


def _verify_bearer(header_val: str | None) -> bool:
    if not header_val or not header_val.startswith("Bearer "):
        return False
    token = header_val[7:].strip()
    from hmac import compare_digest

    return compare_digest(token.encode("utf-8"), CFG.shared_secret.encode("utf-8"))


def _fqdn(hostname: str) -> str:
    return f"{hostname}.{CFG.dns_zone}."


def _ipv4_reverse_parts(ip: str) -> tuple[str, str]:
    o1, o2, o3, o4 = ip.split(".")
    ptr_owner = f"{o4}.{o3}.{o2}.{o1}.in-addr.arpa."
    rev_zone = f"{o3}.{o2}.{o1}.in-addr.arpa"
    return ptr_owner, rev_zone


def _run_locked(fn: Any) -> None:
    os.makedirs(os.path.dirname(_LOCK_PATH) or ".", exist_ok=True)
    with open(_LOCK_PATH, "a+", encoding="utf-8") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        try:
            fn()
        finally:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)


def _kinit() -> None:
    env = os.environ.copy()
    env["KRB5_KTNAME"] = CFG.krb_kt
    ccache = os.environ.get("KRB5CCNAME", "FILE:/tmp/ddns-nsupdate.ccache")
    env["KRB5CCNAME"] = ccache
    r = subprocess.run(
        ["kinit", "-k", "-t", CFG.krb_kt, CFG.krb_principal],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    if r.returncode != 0:
        parts: list[str] = [f"rc={r.returncode}"]
        if r.stderr and r.stderr.strip():
            parts.append(f"stderr={r.stderr.strip()}")
        if r.stdout and r.stdout.strip():
            parts.append(f"stdout={r.stdout.strip()}")
        detail = "; ".join(parts)
        LOG.error("kinit failed: %s", detail)
        raise RuntimeError(f"kinit_failed: {detail}")


def _dig_a(fqdn: str) -> list[str]:
    r = subprocess.run(
        [
            "dig",
            "+short",
            fqdn,
            "A",
            f"@{CFG.nsupdate_server}",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode != 0:
        return []
    ips: list[str] = []
    for line in r.stdout.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ipaddress.IPv4Address(line)
            ips.append(line)
        except ValueError:
            continue
    return ips


def _dig_ptr(ip: str) -> str | None:
    """Return first PTR target (FQDN without trailing dot) or None."""
    r = subprocess.run(
        [
            "dig",
            "+short",
            "-x",
            ip,
            f"@{CFG.nsupdate_server}",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode != 0:
        return None
    for line in r.stdout.strip().splitlines():
        line = line.strip().rstrip(".")
        if line:
            return line
    return None


def _hostname_label_from_ptr_target(ptr_target: str) -> str | None:
    """If ptr_target is a single DNS label under CFG.dns_zone, return that label."""
    z = CFG.dns_zone.lower().rstrip(".")
    name = ptr_target.lower().rstrip(".")
    suffix = f".{z}"
    if not name.endswith(suffix) or name == z:
        return None
    rest = name[: -len(suffix)]
    if not rest or "." in rest:
        return None
    if not _HOSTNAME_LABEL.fullmatch(rest):
        return None
    return rest


def _nsupdate_batch(commands: str) -> None:
    env = os.environ.copy()
    env["KRB5_KTNAME"] = CFG.krb_kt
    env["KRB5CCNAME"] = os.environ.get("KRB5CCNAME", "FILE:/tmp/ddns-nsupdate.ccache")
    r = subprocess.run(
        ["nsupdate", "-g"],
        input=commands,
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    if r.returncode != 0:
        LOG.warning("nsupdate failed rc=%s stderr=%s out=%s", r.returncode, r.stderr, r.stdout)
        raise RuntimeError(f"nsupdate_failed:{r.stderr or r.stdout}")


def handle_upsert_v4(hostname: str, ip: str) -> None:
    fq = _fqdn(hostname)
    ptr_owner, rev_zone = _ipv4_reverse_parts(ip)
    ttl = CFG.ttl

    def _do() -> None:
        _kinit()
        lines: list[str] = [
            f"server {CFG.nsupdate_server} {CFG.dns_port}",
            f"realm {CFG.krb_realm}",
        ]
        old_ips = [x for x in _dig_a(fq) if x != ip]
        for old in old_ips:
            op, rz = _ipv4_reverse_parts(old)
            lines.append(f"zone {rz}")
            lines.append(f"update delete {op} PTR")
            lines.append("send")
        lines.append(f"zone {CFG.dns_zone}")
        lines.append(f"update delete {fq} A")
        lines.append(f"update add {fq} {ttl} IN A {ip}")
        lines.append("send")
        lines.append(f"zone {rev_zone}")
        lines.append(f"update add {ptr_owner} {ttl} IN PTR {fq}")
        lines.append("send")
        _nsupdate_batch("\n".join(lines) + "\n")

    _run_locked(_do)


def handle_delete_v4(ip: str, hostname: str) -> None:
    """Remove PTR for ip always; remove A for hostname, or infer hostname from PTR if hostname is ""."""
    ptr_owner, rev_zone = _ipv4_reverse_parts(ip)
    host_label: str | None = None
    if hostname:
        host_label = hostname
    else:
        target = _dig_ptr(ip)
        if target:
            host_label = _hostname_label_from_ptr_target(target)
            if host_label:
                LOG.info("delete v4 ip=%s inferred host=%s from ptr=%s", ip, host_label, target)
            else:
                LOG.info("delete v4 ip=%s ptr=%s not a single-label name in %s", ip, target, CFG.dns_zone)

    def _do() -> None:
        _kinit()
        lines: list[str] = [
            f"server {CFG.nsupdate_server} {CFG.dns_port}",
            f"realm {CFG.krb_realm}",
        ]
        if host_label:
            fq = _fqdn(host_label)
            lines.append(f"zone {CFG.dns_zone}")
            lines.append(f"update delete {fq} A {ip}")
            lines.append("send")
        lines.append(f"zone {rev_zone}")
        lines.append(f"update delete {ptr_owner} PTR")
        lines.append("send")
        _nsupdate_batch("\n".join(lines) + "\n")

    _run_locked(_do)


def handle_upsert_aaaa(hostname: str, ip: str) -> None:
    fq = _fqdn(hostname)
    ttl = CFG.ttl

    def _do() -> None:
        _kinit()
        lines = [
            f"server {CFG.nsupdate_server} {CFG.dns_port}",
            f"realm {CFG.krb_realm}",
            f"zone {CFG.dns_zone}",
            f"update delete {fq} AAAA",
            f"update add {fq} {ttl} IN AAAA {ip}",
            "send",
        ]
        _nsupdate_batch("\n".join(lines) + "\n")

    _run_locked(_do)


def handle_delete_aaaa(hostname: str, ip: str) -> None:
    fq = _fqdn(hostname)

    def _do() -> None:
        _kinit()
        lines = [
            f"server {CFG.nsupdate_server} {CFG.dns_port}",
            f"realm {CFG.krb_realm}",
            f"zone {CFG.dns_zone}",
            f"update delete {fq} AAAA {ip}",
            "send",
        ]
        _nsupdate_batch("\n".join(lines) + "\n")

    _run_locked(_do)


def _validate_hostname(h: str) -> str:
    if not h or not _HOSTNAME_LABEL.fullmatch(h):
        raise ValueError("invalid_hostname")
    return h


def dispatch(action: str, address: str, hostname: str) -> None:
    h_clean = (hostname or "").strip().lower()
    try:
        v4 = ipaddress.IPv4Address(address)
    except ValueError:
        v4 = None
    if v4 is not None:
        v4s = str(v4)
        if action == "upsert":
            handle_upsert_v4(_validate_hostname(h_clean), v4s)
        elif h_clean:
            handle_delete_v4(v4s, _validate_hostname(h_clean))
        else:
            handle_delete_v4(v4s, "")
        return

    try:
        v6 = ipaddress.IPv6Address(address)
    except ValueError as exc:
        raise ValueError("invalid_address") from exc
    v6s = v6.compressed
    if action == "upsert":
        handle_upsert_aaaa(_validate_hostname(h_clean), v6s)
    else:
        if not h_clean:
            raise ValueError("invalid_hostname")
        handle_delete_aaaa(_validate_hostname(h_clean), v6s)


class Handler(BaseHTTPRequestHandler):
    server_version = "ddns-nsupdate/1"

    def log_message(self, fmt: str, *args: Any) -> None:
        LOG.info("%s - %s", self.address_string(), fmt % args)

    def _send(self, code: int, body: bytes | None = None, ctype: str = "text/plain; charset=utf-8") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body or b"")))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.rstrip("/") == "/ddns/v1/health":
            self._send(200, b"ok\n")
            return
        self._send(404, b"/ddns/v1/health\n")

    def do_POST(self) -> None:  # noqa: N802
        if self.path.rstrip("/") != "/ddns/v1/lease":
            self._send(404, b"not found\n")
            return
        if not _verify_bearer(self.headers.get("Authorization")):
            self._send(401, b"unauthorized\n")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, b"bad length\n")
            return
        if length <= 0 or length > _MAX_BODY:
            self._send(400, b"bad body size\n")
            return
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send(400, b"invalid json\n")
            return
        action = str(data.get("action", "")).lower()
        address = str(data.get("address", "")).strip()
        hostname = str(data.get("hostname", "")).strip().lower()
        if action not in ("upsert", "delete"):
            self._send(400, b"bad action\n")
            return
        try:
            dispatch(action, address, hostname)
        except ValueError as exc:
            self._send(400, (str(exc) + "\n").encode())
            return
        except RuntimeError as exc:
            # kinit/nsupdate failures include detail in exc message; avoid duplicate stack traces.
            LOG.error("ddns failed: %s", exc)
            self._send(502, (str(exc) + "\n").encode())
            return
        self._send(200, b'{"ok":true}\n', ctype="application/json; charset=utf-8")


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )
    addr = (CFG.listen_addr, CFG.listen_port)
    httpd = HTTPServer(addr, Handler)
    LOG.info("listening on %s:%s", CFG.listen_addr, CFG.listen_port)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
