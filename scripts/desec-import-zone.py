#!/usr/bin/env python3
"""Creates the records from a BIND zone file in a deSEC domain.

Records are grouped into RRsets and sent in a single bulk PATCH, so RRsets in
the file are created or replaced, while RRsets not in the file are left alone.
Running it again is safe. SOA and apex NS records are skipped (deSEC manages
them). The domain is created first if it does not exist yet.

TTLs below deSEC's minimum (3600) are raised to it; Cloudflare exports "auto"
as TTL 1. Use --ttl to force one TTL for every RRset.

Usage: DESEC_TOKEN=... scripts/desec-import-zone.py [--dry-run] [--ttl N] DOMAIN ZONEFILE
"""
import argparse
import json
import os
import re
import shlex
import sys
import urllib.error
import urllib.request

API = "https://desec.io/api/v1"
MIN_TTL = 3600


def parse_zone(path, domain):
    """Returns {(subname, type): {"ttl": int, "records": [str]}}."""
    origin = domain.rstrip(".") + "."
    default_ttl = MIN_TTL
    last_name = origin
    rrsets = {}

    with open(path) as f:
        for line in f:
            line = strip_comment(line).rstrip()
            if not line.strip():
                continue
            if line.startswith("$ORIGIN"):
                origin = line.split()[1]
                continue
            if line.startswith("$TTL"):
                default_ttl = int(line.split()[1])
                continue

            tokens = [(m.group(), m.end()) for m in re.finditer(r"\S+", line)]
            # A line starting with whitespace reuses the previous owner name.
            if line[0].isspace():
                name = last_name
            else:
                name = absolute(tokens.pop(0)[0], origin)
                last_name = name

            # Class and TTL may come in either order before the type.
            ttl = default_ttl
            while tokens[0][0].upper() in ("IN", "CH", "HS") or tokens[0][0].isdigit():
                tok = tokens.pop(0)[0]
                if tok.isdigit():
                    ttl = int(tok)
            rtype, end = tokens.pop(0)
            rtype = rtype.upper()
            rdata = line[end:].strip()

            subname = subname_of(name, domain)
            if rtype == "SOA" or (rtype == "NS" and subname == ""):
                continue

            rrset = rrsets.setdefault((subname, rtype), {"ttl": ttl, "records": []})
            rrset["ttl"] = min(rrset["ttl"], ttl)
            record = normalize(rtype, rdata)
            if record not in rrset["records"]:
                rrset["records"].append(record)
    return rrsets


def strip_comment(line):
    """Removes a ; comment, ignoring semicolons inside quoted strings."""
    quoted = False
    for i, c in enumerate(line):
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            quoted = not quoted
        elif c == ";" and not quoted:
            return line[:i]
    return line


def absolute(name, origin):
    if name == "@":
        return origin
    return name if name.endswith(".") else f"{name}.{origin}"


def subname_of(name, domain):
    name = name.rstrip(".").lower()
    domain = domain.rstrip(".").lower()
    if name == domain:
        return ""
    if not name.endswith("." + domain):
        sys.exit(f"{name} is not inside {domain}")
    return name[: -len(domain) - 1]


def normalize(rtype, rdata):
    # Cloudflare exports a null target ("." as in RFC 2782) as "..".
    parts = [". " if p == ".." else p for p in rdata.split()]
    rdata = " ".join(p.strip() for p in parts)
    if rtype == "TXT":
        # deSEC wants each string quoted; re-quote to normalize spacing.
        return " ".join(json.dumps(s) for s in shlex.split(rdata))
    return rdata


def request(method, path, token, body=None):
    req = urllib.request.Request(
        API + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "Authorization": f"Token {token}",
            "Content-Type": "application/json",
            "User-Agent": "desec-import-zone",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            data = resp.read()
            return resp.status, json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("domain")
    p.add_argument("zonefile")
    p.add_argument("--ttl", type=int, help="TTL for every RRset (default: from file, at least %d)" % MIN_TTL)
    p.add_argument("--dry-run", action="store_true", help="print the RRsets instead of sending them")
    args = p.parse_args()
    domain = args.domain.rstrip(".")

    body = [
        {
            "subname": subname,
            "type": rtype,
            "ttl": args.ttl or max(rrset["ttl"], MIN_TTL),
            "records": rrset["records"],
        }
        for (subname, rtype), rrset in sorted(parse_zone(args.zonefile, domain).items())
    ]

    if args.dry_run:
        print(json.dumps(body, indent=2))
        return

    token = os.environ.get("DESEC_TOKEN") or sys.exit("DESEC_TOKEN is not set")

    status, data = request("GET", f"/domains/{domain}/", token)
    if status == 404:
        print(f"Creating domain {domain}")
        status, data = request("POST", "/domains/", token, {"name": domain})
    if status not in (200, 201):
        sys.exit(f"Failed to get/create {domain}: HTTP {status}: {data}")

    status, result = request("PATCH", f"/domains/{domain}/rrsets/", token, body)
    if status != 200:
        sys.exit(f"Failed to create records: HTTP {status}: {result}")
    for rrset in result:
        print(f"{rrset['name']:40} {rrset['ttl']:>5} {rrset['type']:6} {len(rrset['records'])} record(s)")

    print("\nDS records to set at the registrar:")
    for key in data.get("keys", []):
        for ds in key.get("ds", []):
            print(f"  {ds}")


if __name__ == "__main__":
    main()
