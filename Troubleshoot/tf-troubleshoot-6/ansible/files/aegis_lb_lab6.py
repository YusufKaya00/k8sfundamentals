import http.server
import json
import sys
import urllib.request

CFG_PATH = sys.argv[1]
with open(CFG_PATH, "r") as f:
    CFG = json.load(f)

PORT = int(CFG["listen_port"])
UPSTREAMS = CFG["upstreams"]

class LBHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/cluster-status":
            results = []
            all_ok = True
            for url in UPSTREAMS:
                try:
                    with urllib.request.urlopen(url, timeout=2) as resp:
                        results.append(json.loads(resp.read().decode("utf-8")))
                except urllib.error.HTTPError as he:
                    all_ok = False
                    results.append(json.loads(he.read().decode("utf-8")))
                except Exception as e:
                    all_ok = False
                    results.append({"upstream": url, "error": str(e)})
            code = 200 if (all_ok and len(results) == 2) else 502
            body = json.dumps({
                "lb_status": "HEALTHY" if code == 200 else "DEGRADED_502",
                "active_workers": len(results),
                "backends": results
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
    server = http.server.HTTPServer(("127.0.0.1", PORT), LBHandler)
    server.serve_forever()
