#!/usr/bin/env python3
"""
Локальный хост для device_emulator.html + прокси к SmartVend paygate.

Зачем он нужен: paygate не отдаёт CORS-заголовки (OPTIONS на /api/v1/device/enroll
возвращает 405 без Access-Control-*), поэтому страница, открытая как file:// или с
чужого origin, не может обратиться к нему напрямую. Прокси решает это тем, что
отдаёт и страницу, и API с одного origin — CORS вообще не участвует.

    python paygate_proxy.py
    # → http://127.0.0.1:8787/device_emulator.html

Всё, что приходит на /api/..., дословно пересылается на upstream: метод, тело,
Authorization, а обратно — статус, тело и Retry-Aftfer. Ничего не переписывается,
чтобы эмулятор видел ровно тот протокол, что и прошивка.

    python paygate_proxy.py --upstream https://paygate.smartvend.kz   # прод
    python paygate_proxy.py --port 9000 --no-browser

Только стандартная библиотека, зависимостей нет.
"""

import argparse
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser

DEFAULT_UPSTREAM = "https://paygatestage.smartvend.kz"
DEFAULT_PORT = 8787

# Заголовки, которые имеет смысл тащить в обе стороны. Hop-by-hop и всё, что
# относится к транспорту, намеренно отбрасывается.
FORWARD_REQUEST_HEADERS = ("authorization", "content-type", "accept", "user-agent")
FORWARD_RESPONSE_HEADERS = ("content-type", "retry-after", "www-authenticate", "location")

ARGS = None


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # ---------- статика ----------
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ARGS.root, **kw)

    def log_message(self, fmt, *a):  # тише, чем дефолт: свои строки печатаем сами
        pass

    def end_headers(self):
        # Страницу правим часто — кеш только мешает.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    # ---------- маршрутизация ----------
    def do_GET(self):
        if self._is_api():
            return self._proxy("GET")
        if self.path == "/":
            self.send_response(302)
            self.send_header("Location", "/" + ARGS.page)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        return super().do_GET()

    def do_HEAD(self):
        if self._is_api():
            return self._proxy("HEAD")
        return super().do_HEAD()

    def do_POST(self):
        return self._proxy("POST") if self._is_api() else self._not_found()

    def do_PUT(self):
        return self._proxy("PUT") if self._is_api() else self._not_found()

    def do_DELETE(self):
        return self._proxy("DELETE") if self._is_api() else self._not_found()

    def do_OPTIONS(self):
        # Нужен только если страницу открыли не с этого origin (например file://).
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _is_api(self):
        return self.path.startswith("/api/")

    def _not_found(self):
        self._send(404, b'{"detail":"not found"}', {"Content-Type": "application/json"})

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "authorization, content-type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Max-Age", "86400")

    def _send(self, status, body, headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    # ---------- прокси ----------
    def _proxy(self, method):
        url = ARGS.upstream.rstrip("/") + self.path

        length = int(self.headers.get("Content-Length") or 0)
        payload = self.rfile.read(length) if length else None

        headers = {}
        for name in FORWARD_REQUEST_HEADERS:
            value = self.headers.get(name)
            if value:
                headers[name] = value
        headers.setdefault("accept", "application/json")

        req = urllib.request.Request(url, data=payload, method=method, headers=headers)
        started = time.time()
        try:
            with urllib.request.urlopen(req, timeout=ARGS.timeout) as resp:
                status, raw, got = resp.status, resp.read(), resp.headers
        except urllib.error.HTTPError as e:
            # 4xx/5xx — это нормальный ответ протокола, а не сбой прокси.
            status, raw, got = e.code, e.read(), e.headers
        except Exception as e:
            status, raw, got = 502, json.dumps(
                {"detail": "proxy could not reach upstream", "error": str(e)}
            ).encode(), None
        elapsed = int((time.time() - started) * 1000)

        out = {"Content-Type": "application/json"}
        if got:
            for name in FORWARD_RESPONSE_HEADERS:
                value = got.get(name)
                if value:
                    out[name.title()] = value

        self._log(method, self.path, status, elapsed, payload, raw)
        self._send(status, raw, out)

    def _log(self, method, path, status, ms, req_body, res_body):
        colour = "\033[32m" if status < 400 else ("\033[33m" if status < 500 else "\033[31m")
        if not ARGS.colour:
            colour = ""
        reset = "\033[0m" if ARGS.colour else ""
        print(f"{colour}{status}{reset} {method:<6} {path}  {ms} ms")
        if ARGS.verbose:
            if req_body:
                print(f"        >> {_trim(req_body)}")
            if res_body:
                print(f"        << {_trim(res_body)}")


def _trim(b, limit=400):
    try:
        s = b.decode("utf-8", "replace")
    except Exception:
        return repr(b[:limit])
    s = " ".join(s.split())
    return s if len(s) <= limit else s[:limit] + "..."


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    global ARGS
    here = os.path.dirname(os.path.abspath(__file__))

    # Консоль Windows часто живёт в cp866/cp1251 — не даём ей уронить процесс
    # на символе, которого нет в её кодировке.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, ValueError):
            pass

    p = argparse.ArgumentParser(description="Хост эмулятора + CORS-прокси к paygate")
    p.add_argument("--upstream", default=DEFAULT_UPSTREAM, help=f"базовый URL API (по умолчанию {DEFAULT_UPSTREAM})")
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--root", default=here, help="каталог со статикой")
    p.add_argument("--page", default="pay_test.html",
                   help="какую страницу открывать (pay_test.html или device_emulator.html)")
    p.add_argument("--timeout", type=float, default=30.0)
    p.add_argument("-v", "--verbose", action="store_true", help="печатать тела запросов и ответов")
    p.add_argument("--no-browser", dest="browser", action="store_false")
    p.add_argument("--no-colour", dest="colour", action="store_false")
    ARGS = p.parse_args()

    url = f"http://{ARGS.host}:{ARGS.port}/{ARGS.page}"
    print("SmartVend device emulator")
    print(f"  страница : {url}")
    print(f"  upstream : {ARGS.upstream}")
    print(f"  статика  : {ARGS.root}")
    print("  /api/*  ->  upstream, всё остальное — файлы. Ctrl+C для выхода.\n")

    if ARGS.browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()

    try:
        with Server((ARGS.host, ARGS.port), Handler) as srv:
            srv.serve_forever()
    except KeyboardInterrupt:
        print("\nостановлено")
    except OSError as e:
        print(f"не удалось занять {ARGS.host}:{ARGS.port} — {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
