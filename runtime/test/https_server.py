#!/usr/bin/env python3
"""Loopback-only HTTPS fixture for the macOS runtime transport tests."""

from __future__ import annotations

import argparse
import http.server
import socketserver
import ssl
import time
from pathlib import Path


RESPONSE_CAP = 5 * 1024 * 1024


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, status: int, body: bytes, headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/success":
            self._send(200, f"GET|{self.headers.get('X-Weaver-Test', '')}|ok".encode())
        elif self.path == "/redirect":
            self._send(302, b"redirect-not-followed", {"Location": "https://example.invalid/escape"})
        elif self.path == "/oversized":
            self._send(200, b"x" * (RESPONSE_CAP + 1))
        elif self.path == "/slow":
            time.sleep(2)
            self._send(200, b"late")
        else:
            self._send(404, b"missing")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self._send(201, b"POST|" + self.headers.get("X-Weaver-Test", "").encode() + b"|" + body)

    def log_message(self, _format: str, *_args: object) -> None:
        pass


class TLSServer(http.server.ThreadingHTTPServer):
    def __init__(self, address: tuple[str, int], handler: type[Handler], context: ssl.SSLContext) -> None:
        super().__init__(address, handler)
        self._context = context

    def server_bind(self) -> None:
        # HTTPServer resolves the bind address through getfqdn(), which can
        # block on runner DNS even for 127.0.0.1. The fixture needs no public
        # hostname; keep readiness wholly loopback and deterministic.
        socketserver.TCPServer.server_bind(self)
        self.server_name = str(self.server_address[0])
        self.server_port = int(self.server_address[1])

    def get_request(self):  # type annotations differ across supported Python releases
        connection, address = super().get_request()
        return self._context.wrap_socket(connection, server_side=True), address


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    server = TLSServer(("127.0.0.1", 0), Handler, context)
    port_file = Path(args.port_file)
    port_file_tmp = port_file.with_suffix(".tmp")
    port_file_tmp.write_text(str(server.server_port), encoding="ascii")
    port_file_tmp.replace(port_file)
    server.serve_forever(poll_interval=0.05)


if __name__ == "__main__":
    main()
