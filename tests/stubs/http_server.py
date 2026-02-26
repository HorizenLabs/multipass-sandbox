#!/usr/bin/env python3
"""Lightweight HTTP server for BATS integration tests.

Serves files from a directory with proper Last-Modified / If-Modified-Since
(304) handling and error simulation via /__error/<code>/ path prefix.

Usage: python3 http_server.py <fixtures_dir> <ready_file>
  - Binds to 127.0.0.1:0 (OS-assigned port, parallel-safe)
  - Writes the assigned port number to <ready_file> when listening
  - Suppresses per-request logging (only stderr on fatal errors)
"""

import os
import sys
from http.server import SimpleHTTPRequestHandler, HTTPServer


class QuietHandler(SimpleHTTPRequestHandler):
    """File server with 304 support and error simulation."""

    def log_message(self, format, *args):
        """Suppress stdout request logging."""

    def do_GET(self):
        code = self._error_code()
        if code:
            self.send_error(code)
            return
        super().do_GET()

    def do_HEAD(self):
        code = self._error_code()
        if code:
            self.send_error(code)
            return
        super().do_HEAD()

    def _error_code(self):
        """Return an HTTP error code if the path matches /__error/<code>/."""
        if self.path.startswith("/__error/"):
            parts = self.path.split("/")  # ['', '__error', '<code>', ...]
            if len(parts) >= 3 and parts[2].isdigit():
                return int(parts[2])
        return 0


def main():
    if len(sys.argv) != 3:
        print("Usage: http_server.py <fixtures_dir> <ready_file>", file=sys.stderr)
        sys.exit(1)

    fixtures_dir = sys.argv[1]
    ready_file = sys.argv[2]

    os.chdir(fixtures_dir)
    server = HTTPServer(("127.0.0.1", 0), QuietHandler)
    port = server.server_address[1]

    with open(ready_file, "w") as f:
        f.write(str(port))

    server.serve_forever()


if __name__ == "__main__":
    main()
