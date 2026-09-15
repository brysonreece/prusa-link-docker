#!/opt/venv/bin/python
"""Container healthcheck for PrusaLink.

HEAD / is the only unauthenticated route on the web server (web/main.py:71 --
it returns an Instance-ID header for instance pairing and carries no auth
decorator), which makes it the one endpoint that can prove the WSGI server is
live without baking an API key into the image.

The port is read from prusalink.ini rather than an environment variable so the
check stays correct when the operator edits the config by hand.
"""
import configparser
import http.client
import os
import sys

CONFIG_FILE = os.environ.get("PRUSALINK_CONFIG_DIR", "/etc/prusalink") + "/prusalink.ini"


def configured_port() -> int:
    parser = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
    try:
        parser.read(CONFIG_FILE)
        return parser.getint("http", "port", fallback=8080)
    except (configparser.Error, ValueError, OSError):
        return 8080


def main() -> int:
    conn = http.client.HTTPConnection("127.0.0.1", configured_port(), timeout=5)
    try:
        conn.request("HEAD", "/")
        return 0 if conn.getresponse().status == 200 else 1
    except (OSError, http.client.HTTPException):
        return 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
