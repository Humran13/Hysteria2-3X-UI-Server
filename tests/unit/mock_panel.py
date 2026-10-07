#!/usr/bin/env python3
"""Behaviour-focused 3X-UI v3.9.0 mock for Hysteria2 tests.
  * Bearer-token auth (401 for a wrong token, 404 without auth), {"success","msg","obj"} envelope
  * full client replacement, Hysteria auth generation/preservation, duplicate checks
  * deleting an inbound leaves clients orphaned
Fault injection: POST /__ctl  {"fail": {"<path substring>": "500|malformed|success_false|401|drop"}, "reset": true}
Upstream mock: /web/releases/latest (302), /api/releases/latest, /raw/<tag>/<script>
Usage: mock_panel.py PORT BASEPATH TOKEN STATEFILE [UPSTREAM_DIR]
"""
import base64
import json
import os
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse, quote

PORT = int(sys.argv[1])
BASE = sys.argv[2].strip("/")
TOKEN = sys.argv[3]
UPSTREAM_DIR = sys.argv[5] if len(sys.argv) > 5 else ""

S = {
    "inbounds": [],
    "clients": {},  # email -> record
    "tokens": [{"id": 1, "name": "default", "token": TOKEN, "enabled": True}],
    "next_inbound": 1,
    "next_client": 1,
    "next_token": 2,
    "fail": {},
    "log": [],
    "latest_tag": "v3.9.0",
    "opt": {},
}


def keygen():
    return base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")


def ok(obj=None, msg=""):
    return 200, {"success": True, "msg": msg, "obj": obj}


def err(msg):
    return 200, {"success": False, "msg": msg, "obj": None}


def stream_of(inb):
    s = inb.get("streamSettings") or {}
    return json.loads(s) if isinstance(s, str) else s


def link_for(inb, c):
    st = stream_of(inb)
    tls = st.get("tlsSettings") or {}
    ts = tls.get("settings") or {}
    q = {"security": "tls", "alpn": ",".join(tls.get("alpn") or ["h3"]), "sni": tls.get("serverName", "")}
    pins = ts.get("pinnedPeerCertSha256") or []
    if pins:
        q["pinSHA256"] = ",".join(pins)
    host = inb.get("shareAddr") or "localhost"
    qs = "&".join(f"{k}={quote(str(v), safe='')}" for k, v in sorted(q.items()))
    return f"hysteria2://{quote(c['auth'], safe='')}@{host}:{inb['port']}?{qs}#{inb['remark']}-{c['email']}"


def client_view(c):
    v = dict(c)
    v["id"] = c["rid"]
    return v


def inbound_view(inb):
    v = dict(inb)
    ids = inb["id"]
    v["clientStats"] = [{"email": e} for e, c in S["clients"].items() if ids in c["inboundIds"]]
    return v


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json", extra=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _fault(self, path):
        for k, mode in S["fail"].items():
            if k in path:
                return mode
        return None

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        u = urlparse(self.path)
        path = u.path
        S["log"].append(f"{method} {path}")
        # ---- control channel
        if path == "/__ctl":
            d = json.loads(self._body() or b"{}")
            if d.get("reset"):
                S["fail"] = {}
            S["fail"].update(d.get("fail", {}))
            if "latest_tag" in d:
                S["latest_tag"] = d["latest_tag"]
            S["opt"].update(d.get("opt", {}))
            return self._send(200, {"ok": True})
        if path == "/__state":
            return self._send(200, {k: v for k, v in S.items() if k != "tokens"})
        # ---- upstream (GitHub) mock
        if path == "/web/releases/latest":
            tag = S["latest_tag"]
            return self._send(302, b"", "text/plain", {"Location": f"/web/releases/tag/{tag}"})
        if path.startswith("/web/releases/tag/"):
            return self._send(200, b"ok", "text/plain")
        if path == "/api/releases/latest":
            return self._send(200, {"tag_name": S["latest_tag"], "prerelease": False, "draft": False})
        m = re.match(r"^/raw/([^/]+)/(.+)$", path)
        if m and UPSTREAM_DIR:
            f = os.path.join(UPSTREAM_DIR, m.group(1), m.group(2))
            if os.path.isfile(f):
                return self._send(200, open(f, "rb").read(), "text/plain")
            return self._send(404, b"not found", "text/plain")
        # ---- panel API
        prefix = "/" + BASE if BASE else ""
        if not path.startswith(prefix + "/panel/api/"):
            return self._send(404, b"404 page not found", "text/plain")
        rel = path[len(prefix):]
        mode = self._fault(rel)
        if mode == "drop":
            self.close_connection = True
            return
        auth = self.headers.get("Authorization", "")
        tok = auth[7:] if auth.startswith("Bearer ") else None
        valid = any(t["token"] == tok and t["enabled"] for t in S["tokens"])
        if not valid:
            return self._send(401 if tok is not None else 404, b"", "text/plain")
        if mode == "401":
            return self._send(401, b"", "text/plain")
        if mode == "500":
            return self._send(500, b"boom", "text/plain")
        if mode == "malformed":
            return self._send(200, b"<html>not json</html>", "text/html")
        if mode == "success_false":
            return self._send(200, {"success": False, "msg": "injected failure", "obj": None})
        code, obj = self.api(method, rel[len("/panel/api"):], u)
        if isinstance(obj, bytes):
            return self._send(code, obj, "application/octet-stream")
        return self._send(code, obj)

    def api(self, method, p, u):
        body = self._body()
        js = {}
        if body and self.headers.get("Content-Type", "").startswith("application/json"):
            try:
                js = json.loads(body)
            except ValueError:
                return err("bad json")
        # server
        if p == "/openapi.json":
            paths = ["/panel/api/inbounds/add", "/panel/api/inbounds/list", "/panel/api/inbounds/update/{id}",
                     "/panel/api/inbounds/del/{id}", "/panel/api/inbounds/get/{id}", "/panel/api/clients/add",
                     "/panel/api/clients/list", "/panel/api/clients/get/{email}", "/panel/api/clients/update/{email}",
                     "/panel/api/clients/del/{email}", "/panel/api/clients/links/{email}",
                     "/panel/api/server/getDb", "/panel/api/server/importDB",
                     "/panel/api/server/status", "/panel/api/setting/apiTokens/create"]
            if S["opt"].get("openapi_missing"):
                paths.remove("/panel/api/clients/add")
            if S["opt"].get("no_openapi"):
                return 404, b"nope"
            return 200, {"paths": {x: {} for x in paths}}
        if p == "/server/status":
            return ok({"xray": {"state": S["opt"].get("xray_state", "running"), "version": "26.9.9"}})
        if p == "/server/restartXrayService":
            return ok(None)
        if p == "/server/getDb":
            snap = json.dumps({k: S[k] for k in ("inbounds", "clients", "tokens", "next_inbound", "next_client", "next_token")})
            return 200, b"SQLite format 3\x00" + snap.encode()
        if p == "/server/importDB":
            i = body.find(b"SQLite format 3\x00")
            if i < 0:
                return err("not a database")
            j = body.find(b"\r\n--", i)
            snap = json.loads(body[i + 16:j if j > 0 else None])
            for k, v in snap.items():
                S[k] = v
            return ok("The database has been successfully imported.")
        # api tokens
        if p == "/setting/apiTokens":
            return ok([{"id": t["id"], "name": t["name"], "enabled": t["enabled"]} for t in S["tokens"]])
        if p == "/setting/apiTokens/create":
            t = {"id": S["next_token"], "name": js.get("name", "t"), "token": keygen(), "enabled": True}
            S["next_token"] += 1
            S["tokens"].append(t)
            return ok({"id": t["id"], "name": t["name"], "token": t["token"], "scope": "admin"})
        m = re.match(r"^/setting/apiTokens/delete/(\d+)$", p)
        if m:
            S["tokens"] = [t for t in S["tokens"] if t["id"] != int(m.group(1))]
            return ok(None)
        # inbounds
        if p == "/inbounds/list":
            return ok([inbound_view(i) for i in S["inbounds"]])
        m = re.match(r"^/inbounds/get/(\d+)$", p)
        if m:
            for i in S["inbounds"]:
                if i["id"] == int(m.group(1)):
                    return ok(inbound_view(i))
            return err("record not found")
        if p == "/inbounds/add":
            for i in S["inbounds"]:
                if i["port"] == js.get("port"):
                    return err(f"port {js.get('port')} (udp) already used by inbound '{i['remark']}' (#{i['id']}) on *")
            inb = dict(js)
            inb["id"] = S["next_inbound"]
            S["next_inbound"] += 1
            inb["tag"] = f"in-{inb['port']}-udp"
            S["inbounds"].append(inb)
            return ok(inbound_view(inb), "Inbound has been successfully created.")
        m = re.match(r"^/inbounds/update/(\d+)$", p)
        if m:
            for k, i in enumerate(S["inbounds"]):
                if i["id"] == int(m.group(1)):
                    new = dict(js)
                    new["id"] = i["id"]
                    new["tag"] = i["tag"]
                    S["inbounds"][k] = new
                    return ok(inbound_view(new))
            return err("record not found")
        m = re.match(r"^/inbounds/del/(\d+)$", p)
        if m:
            iid = int(m.group(1))
            S["inbounds"] = [i for i in S["inbounds"] if i["id"] != iid]
            for c in S["clients"].values():
                c["inboundIds"] = [x for x in c["inboundIds"] if x != iid]
            return ok(iid)
        # clients
        if p == "/clients/list":
            out = []
            for c in S["clients"].values():
                v = client_view(c)
                v["traffic"] = {"up": 0, "down": 0}
                out.append(v)
            return ok(out)
        if p == "/clients/add":
            c = js.get("client") or {}
            email = c.get("email", "")
            if email in S["clients"]:
                return err(f"Something went wrong (email already in use: {email}\n)")
            ids = js.get("inboundIds") or []
            for x in ids:
                if not any(i["id"] == x for i in S["inbounds"]):
                    return err(f"inbound {x} not found")
            rec = {"rid": S["next_client"], "email": email, "uuid": c.get("id") or str(uuid.uuid4()), "subId": str(uuid.uuid4()),
                   "auth": c.get("auth") or keygen(), "flow": "", "enable": c.get("enable", True), "totalGB": c.get("totalGB", 0),
                   "expiryTime": c.get("expiryTime", 0), "comment": c.get("comment", ""), "limitIp": 0, "limitHwid": 0,
                   "tgId": 0, "group": "", "reset": 0, "resetDay": 0, "resetMax": 0, "trafficReset": "never",
                   "trafficResetDay": 1, "inboundIds": list(ids)}
            S["next_client"] += 1
            S["clients"][email] = rec
            return ok(None, "Inbound client(s) have been added.")
        m = re.match(r"^/clients/get/(.+)$", p)
        if m:
            c = S["clients"].get(m.group(1))
            if not c:
                return err("record not found")
            return ok({"client": client_view(c), "inboundIds": c["inboundIds"], "usedTraffic": 0})
        m = re.match(r"^/clients/update/(.+)$", p)
        if m:
            c = S["clients"].get(m.group(1))
            if not c:
                return err("record not found")
            if not isinstance(js.get("id", ""), str):
                return err("json: cannot unmarshal number into Go struct field .id of type string")
            # FULL REPLACE semantics: omitted fields fall back to zero values (this is how flow gets wiped)
            c["uuid"] = js.get("id", "") or c["uuid"]
            c["auth"] = js.get("auth", c.get("auth", ""))
            c["flow"] = ""
            c["enable"] = js.get("enable", False)
            c["totalGB"] = js.get("totalGB", 0)
            c["expiryTime"] = js.get("expiryTime", 0)
            c["comment"] = js.get("comment", "")
            return ok(None, "Inbound client has been updated.")
        m = re.match(r"^/clients/del/(.+)$", p)
        if m:
            if m.group(1) not in S["clients"]:
                return err("record not found")
            del S["clients"][m.group(1)]
            return ok(None)
        m = re.match(r"^/clients/([^/]+)/attach$", p)
        if m:
            c = S["clients"].get(m.group(1))
            if not c:
                return err("record not found")
            for x in js.get("inboundIds", []):
                if x not in c["inboundIds"]:
                    c["inboundIds"].append(x)
            return ok(None)
        m = re.match(r"^/clients/links/(.+)$", p)
        if m:
            c = S["clients"].get(m.group(1))
            if not c:
                return err("record not found")
            links = []
            for iid in c["inboundIds"]:
                for i in S["inbounds"]:
                    if i["id"] == iid:
                        links.append(link_for(i, c))
            return ok(links)
        return err("unknown endpoint " + p)

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    open(sys.argv[4], "w").write(str(srv.server_address[1]))
    srv.serve_forever()
