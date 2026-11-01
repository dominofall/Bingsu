#!/usr/bin/env python3
"""Google Drive API 흉내 서버 (빙수 시뮬레이터 검증용, 표준 라이브러리만).

빙수 디버그 빌드를 BINGSU_ALLOW_HTTP=1 BINGSU_DRIVE_BASE_URL=http://127.0.0.1:<포트> 로 띄우면
동의 화면·토큰·Drive v3 호출이 모두 이 서버로 온다. 파일은 --dir 폴더에 두어 시뮬레이터 두 대가 같은 "Drive" 를 본다.
실제 Google 과 다른 점은 README.md 에 적었다. 비밀값은 다루지 않는다(아무 클라이언트 ID 나 받는다).

    python3 tools/drive-mock/server.py --dir /tmp/drive-mock [--port 8765] [--expires 3600] [--page-size 1000]

흉내 바꾸기:  curl -X POST 'http://127.0.0.1:8765/mock/mode?set=quota'
    normal · quota(올리기 403 storageQuotaExceeded) · invalid_grant(토큰 401 + 갱신 400 invalid_grant)
    expire(지금 액세스 토큰을 한 번 무효로) · rate&count=N(다음 N개 요청 429)
    drop_chunk(다음 이어 올리기 둘째 조각을 받고 응답 없이 끊음) · die_chunk(첫 조각을 저장한 뒤 서버 종료)
상태 보기:   curl http://127.0.0.1:8765/mock/state
"""
import argparse
import base64
import hashlib
import json
import os
import secrets
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
ARGS = None
STATE = None  # meta.json 내용


def now_iso(ts=None):
    t = datetime.fromtimestamp(ts if ts is not None else time.time(), tz=timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def meta_path():
    return os.path.join(ARGS.dir, "meta.json")


def load_state():
    try:
        with open(meta_path()) as f:
            s = json.load(f)
    except (OSError, ValueError):
        s = {}
    for k, v in (("files", {}), ("access", {}), ("refresh", []), ("codes", {}), ("sessions", {}), ("mode", "normal"), ("rate", 0), ("version", 0)):
        s.setdefault(k, v)
    return s


def save_state():
    tmp = meta_path() + ".tmp"
    with open(tmp, "w") as f:
        json.dump(STATE, f, indent=1, sort_keys=True, ensure_ascii=False)
    os.replace(tmp, meta_path())


def content_path(fid):
    f = STATE["files"][fid]
    # 사람이 폴더를 보고 확인할 수 있게 이름을 붙인다 (Drive 처럼 이름이 겹쳐도 id 로 구분)
    return os.path.join(ARGS.dir, "files", f"{fid}__{f['name']}")


def file_json(fid):
    f = STATE["files"][fid]
    return {"id": fid, "name": f["name"], "size": str(f["size"]), "md5Checksum": f["md5"], "modifiedTime": f["modifiedTime"],
            "appProperties": f.get("appProperties", {}), "version": str(f["version"]), "kind": "drive#file"}


def put_content(fid, data, meta, create):
    files = STATE["files"]
    if create:
        files[fid] = {"name": meta.get("name", "untitled"), "parents": meta.get("parents", []), "appProperties": {}}
    f = files[fid]
    old = content_path(fid) if not create else None
    if "name" in meta and not create:
        f["name"] = meta["name"]
    props = f.get("appProperties", {})
    for k, v in (meta.get("appProperties") or {}).items():
        if v is None:
            props.pop(k, None)
        else:
            props[k] = str(v)
    f["appProperties"] = props
    f["size"] = len(data)
    f["md5"] = hashlib.md5(data).hexdigest()
    f["modifiedTime"] = meta.get("modifiedTime") or now_iso()
    STATE["version"] += 1
    f["version"] = STATE["version"]
    if old and old != content_path(fid) and os.path.exists(old):
        os.remove(old)
    with open(content_path(fid), "wb") as out:
        out.write(data)
    save_state()
    return file_json(fid)


def drive_error(code, reason, message):
    return code, {"error": {"code": code, "message": message, "errors": [{"domain": "global", "reason": reason, "message": message}]}}


class Handler(BaseHTTPRequestHandler):
    server_version = "drive-mock/1"

    def log_message(self, fmt, *args):
        # 주소의 쿼리(토큰·코드) 는 남기지 않는다
        sys.stderr.write(f"{datetime.now().strftime('%H:%M:%S')} {self.command} {urllib.parse.urlsplit(self.path).path} {args[1] if len(args) > 1 else ''}\n")

    # ---- 보내기
    def send(self, code, body=None, headers=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else b"")
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if body is not None and raw is None:
            self.send_header("Content-Type", "application/json; charset=UTF-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def parts(self):
        u = urllib.parse.urlsplit(self.path)
        return u.path, dict(urllib.parse.parse_qsl(u.query))

    # ---- 인증
    def authorized(self):
        h = self.headers.get("Authorization", "")
        tok = h[7:] if h.startswith("Bearer ") else ""
        if ARGS.token and tok == ARGS.token:
            return True
        if STATE["mode"] == "invalid_grant":
            return False
        exp = STATE["access"].get(tok)
        return exp is not None and exp > time.time()

    def rate_limited(self):
        if STATE["rate"] > 0:
            STATE["rate"] -= 1
            save_state()
            return True
        return False

    # ---- 경로 나누기
    def do_GET(self):
        with LOCK:
            self.route("GET")

    def do_POST(self):
        with LOCK:
            self.route("POST")

    def do_PATCH(self):
        with LOCK:
            self.route("PATCH")

    def do_PUT(self):
        # die_chunk 는 락 밖에서 끝내지 않게 락 안에서 처리
        with LOCK:
            self.route("PUT")

    def do_DELETE(self):
        with LOCK:
            self.route("DELETE")

    def route(self, method):
        path, q = self.parts()
        if path == "/mock/mode" and method == "POST":
            STATE["mode"] = q.get("set", "normal")
            if STATE["mode"] == "rate":
                STATE["rate"] = int(q.get("count", "2"))
                STATE["mode"] = "normal"
            if STATE["mode"] == "expire":
                STATE["access"] = {k: 0 for k in STATE["access"]}
                STATE["mode"] = "normal"
            save_state()
            return self.send(200, {"mode": STATE["mode"], "rate": STATE["rate"]})
        if path == "/mock/state":
            files = [dict(file_json(i), parents=f.get("parents")) for i, f in sorted(STATE["files"].items())]
            return self.send(200, {"mode": STATE["mode"], "files": files, "sessions": len(STATE["sessions"]),
                                   "refreshTokens": len(STATE["refresh"])})
        if path == "/o/oauth2/v2/auth" and method == "GET":
            return self.auth(q)
        if path == "/token" and method == "POST":
            return self.token(dict(urllib.parse.parse_qsl(self.body().decode())))
        if path == "/revoke" and method == "POST":
            t = dict(urllib.parse.parse_qsl(self.body().decode())).get("token") or q.get("token")
            if t in STATE["refresh"]:
                STATE["refresh"].remove(t)
                save_state()
            return self.send(200, {})

        if path.startswith("/drive/v3/") or path.startswith("/upload/drive/v3/"):
            if not self.authorized():
                return self.send(*drive_error(401, "authError", "Invalid Credentials"))
            if self.rate_limited():
                return self.send(*drive_error(429, "rateLimitExceeded", "Rate Limit Exceeded"))
        if path == "/drive/v3/about" and method == "GET":
            usage = sum(f["size"] for f in STATE["files"].values())
            return self.send(200, {"storageQuota": {"limit": str(15 * 1024 ** 3), "usage": str(usage), "usageInDrive": str(usage)}})
        if path == "/drive/v3/files" and method == "GET":
            return self.list_files(q)
        if path.startswith("/drive/v3/files/"):
            fid = path.rsplit("/", 1)[1]
            if fid not in STATE["files"]:
                return self.send(*drive_error(404, "notFound", f"File not found: {fid}."))
            if method == "GET":
                if q.get("alt") == "media":
                    with open(content_path(fid), "rb") as f:
                        return self.send(200, raw=f.read(), headers={"Content-Type": "application/octet-stream"})
                return self.send(200, file_json(fid))
            if method == "DELETE":
                os.remove(content_path(fid))
                del STATE["files"][fid]
                save_state()
                return self.send(204)
        if path == "/upload/drive/v3/files" or path.startswith("/upload/drive/v3/files/"):
            return self.upload(method, path, q)
        return self.send(404, {"error": "no route"})

    # ---- OAuth
    def auth(self, q):
        redirect = q.get("redirect_uri", "")
        if q.get("code_challenge_method") != "S256" or not q.get("code_challenge") or ":" not in redirect:
            return self.send(400, {"error": "invalid_request"})
        code = "code-" + secrets.token_urlsafe(12)
        STATE["codes"][code] = {"challenge": q["code_challenge"], "redirect": redirect}
        save_state()
        loc = redirect + "?" + urllib.parse.urlencode({"code": code, "state": q.get("state", ""), "scope": q.get("scope", "")})
        return self.send(302, headers={"Location": loc})

    def issue(self, refresh=None):
        at = "at-" + secrets.token_urlsafe(16)
        STATE["access"][at] = time.time() + ARGS.expires
        body = {"access_token": at, "expires_in": ARGS.expires, "token_type": "Bearer",
                "scope": "https://www.googleapis.com/auth/drive.appdata"}
        if refresh:
            body["refresh_token"] = refresh
        save_state()
        return body

    def token(self, form):
        g = form.get("grant_type")
        if g == "authorization_code":
            c = STATE["codes"].pop(form.get("code", ""), None)
            if not c:
                return self.send(400, {"error": "invalid_grant"})
            calc = base64.urlsafe_b64encode(hashlib.sha256(form.get("code_verifier", "").encode()).digest()).rstrip(b"=").decode()
            if calc != c["challenge"] or form.get("redirect_uri") != c["redirect"]:
                save_state()
                return self.send(400, {"error": "invalid_grant", "error_description": "PKCE mismatch"})
            rt = "rt-" + secrets.token_urlsafe(16)
            STATE["refresh"].append(rt)
            return self.send(200, self.issue(refresh=rt))
        if g == "refresh_token":
            if STATE["mode"] == "invalid_grant" or form.get("refresh_token") not in STATE["refresh"]:
                return self.send(400, {"error": "invalid_grant", "error_description": "Token has been expired or revoked."})
            return self.send(200, self.issue())
        return self.send(400, {"error": "unsupported_grant_type"})

    # ---- 목록
    def list_files(self, q):
        if q.get("spaces") != "appDataFolder":
            return self.send(*drive_error(403, "insufficientScopes", "appDataFolder only"))
        ids = sorted(STATE["files"])
        size = min(int(q.get("pageSize", "100")), ARGS.page_size)
        start = int(q.get("pageToken", "0"))
        page = ids[start:start + size]
        body = {"files": [file_json(i) for i in page]}
        if start + size < len(ids):
            body["nextPageToken"] = str(start + size)
        return self.send(200, body)

    # ---- 올리기
    def upload(self, method, path, q):
        fid = path.rsplit("/", 1)[1] if path.startswith("/upload/drive/v3/files/") else None
        if fid and fid not in STATE["files"]:
            return self.send(*drive_error(404, "notFound", f"File not found: {fid}."))
        kind = q.get("uploadType")
        if method == "PUT" and kind == "resumable" and q.get("upload_id"):
            return self.chunk(q["upload_id"])
        if STATE["mode"] == "quota":
            self.body()
            return self.send(*drive_error(403, "storageQuotaExceeded", "The user's Drive storage quota has been exceeded."))
        if kind == "multipart":
            ctype = self.headers.get("Content-Type", "")
            if "boundary=" not in ctype:
                return self.send(400, {"error": "no boundary"})
            boundary = ctype.split("boundary=", 1)[1].strip().strip('"').encode()
            raw = self.body()
            chunks = [c for c in raw.split(b"--" + boundary) if c not in (b"", b"--\r\n", b"--")]
            if len(chunks) < 2:
                return self.send(400, {"error": "bad multipart"})

            def payload(c):
                head, _, rest = c.partition(b"\r\n\r\n")
                return rest[:-2] if rest.endswith(b"\r\n") else rest
            meta = json.loads(payload(chunks[0]) or b"{}")
            data = payload(chunks[1])
            if fid:
                return self.send(200, put_content(fid, data, meta, create=False))
            new = secrets.token_urlsafe(18).replace("-", "a").replace("_", "b")
            return self.send(200, put_content(new, data, meta, create=True))
        if kind == "resumable":
            meta = json.loads(self.body() or b"{}")
            total = int(self.headers.get("X-Upload-Content-Length") or -1)
            sid = secrets.token_urlsafe(12)
            STATE["sessions"][sid] = {"meta": meta, "total": total, "fid": fid, "received": 0}
            open(os.path.join(ARGS.dir, "sessions", sid), "wb").close()
            save_state()
            host = self.headers.get("Host", f"127.0.0.1:{ARGS.port}")
            return self.send(200, {}, headers={"Location": f"http://{host}/upload/drive/v3/files?uploadType=resumable&upload_id={sid}"})
        return self.send(400, {"error": "uploadType"})

    def chunk(self, sid):
        s = STATE["sessions"].get(sid)
        data = self.body()
        if not s:
            return self.send(*drive_error(404, "notFound", "upload session"))
        part = os.path.join(ARGS.dir, "sessions", sid)
        cr = self.headers.get("Content-Range", "")
        if not cr.startswith("bytes "):
            return self.send(400, {"error": "Content-Range"})
        rng, _, total = cr[6:].partition("/")
        total = int(total)
        if rng != "*":
            a, _, b = rng.partition("-")
            a, b = int(a), int(b)
            if STATE["mode"] == "drop_chunk" and a > 0:
                STATE["mode"] = "normal"
                save_state()
                sys.stderr.write("  (drop_chunk: 응답 없이 끊음)\n")
                self.close_connection = True
                self.connection.shutdown(2)
                return
            if a <= s["received"] and b + 1 > s["received"] and len(data) == b - a + 1:
                with open(part, "r+b") as f:
                    f.seek(a)
                    f.write(data)
                    f.truncate(b + 1)
                s["received"] = b + 1
                save_state()
            if STATE["mode"] == "die_chunk" and s["received"] < total:
                STATE["mode"] = "normal"
                save_state()
                sys.stderr.write("  (die_chunk: 조각 저장 뒤 서버 종료)\n")
                sys.stderr.flush()
                os._exit(3)
        if s["received"] >= total:
            with open(part, "rb") as f:
                content = f.read()
            os.remove(part)
            del STATE["sessions"][sid]
            if s.get("done"):
                return self.send(200, file_json(s["done"]))
            if s["fid"]:
                return self.send(200, put_content(s["fid"], content, s["meta"], create=False))
            new = secrets.token_urlsafe(18).replace("-", "a").replace("_", "b")
            return self.send(200, put_content(new, content, s["meta"], create=True))
        headers = {"Range": f"bytes=0-{s['received'] - 1}"} if s["received"] > 0 else {}
        return self.send(308, headers=headers)


def main():
    global ARGS, STATE
    p = argparse.ArgumentParser(description="Google Drive API 흉내 서버 (빙수 검증용)")
    p.add_argument("--dir", required=True, help="파일·상태를 둘 폴더")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--expires", type=int, default=3600, help="액세스 토큰 수명(초)")
    p.add_argument("--page-size", type=int, default=1000, help="목록 한 페이지 최대 개수 (페이지 넘기기 확인용으로 줄일 수 있음)")
    p.add_argument("--token", default="", help="이 고정 토큰도 받는다 (BINGSU_DRIVE_TOKEN 과 함께)")
    ARGS = p.parse_args()
    os.makedirs(os.path.join(ARGS.dir, "files"), exist_ok=True)
    os.makedirs(os.path.join(ARGS.dir, "sessions"), exist_ok=True)
    STATE = load_state()
    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    sys.stderr.write(f"drive-mock: http://127.0.0.1:{ARGS.port}  폴더 {ARGS.dir}  흉내 {STATE['mode']}\n")
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
