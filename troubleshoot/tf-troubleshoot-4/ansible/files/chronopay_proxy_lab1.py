import http.server
import json
import sys
import urllib.request
import urllib.error

CONFIG_PATH = sys.argv[1]
with open(CONFIG_PATH, "r") as f:
    CFG = json.load(f)

LISTEN_PORT = int(CFG["listen_port"])
UPSTREAM_URL = CFG["upstream_url"]
DEPLOY_ID = CFG["deploy_id"]

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            try:
                req = urllib.request.Request(UPSTREAM_URL)
                with urllib.request.urlopen(req, timeout=2) as resp:
                    upstream_data = json.loads(resp.read().decode("utf-8"))
                body = json.dumps({
                    "gateway": "ONLINE",
                    "deploy_id": DEPLOY_ID,
                    "upstream": upstream_data
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                body = json.dumps({
                    "gateway": "ERROR_502_BAD_GATEWAY",
                    "reason": str(e),
                    "attempted_upstream": UPSTREAM_URL
                }).encode("utf-8")
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), ProxyHandler)
    server.serve_forever()
