import http.server
import json
import sys

CFG_PATH = sys.argv[1]
with open(CFG_PATH, "r") as f:
    CFG = json.load(f)

PORT = int(CFG["listen_port"])
SEALED = bool(CFG["sealed"])
CLUSTER_ID = CFG["cluster_id"]

class VaultHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/v1/sys/health":
            code = 503 if SEALED else 200
            body = json.dumps({
                "cluster_id": CLUSTER_ID,
                "sealed": SEALED,
                "listen_port": PORT,
                "status": "SEALED_UNAVAILABLE" if SEALED else "ACTIVE_UNSEALED"
            }).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), VaultHandler)
    server.serve_forever()
