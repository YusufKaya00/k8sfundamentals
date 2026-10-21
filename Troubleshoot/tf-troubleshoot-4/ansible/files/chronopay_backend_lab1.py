import http.server
import json
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19090

class BackendHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/internal/status":
            body = json.dumps({
                "engine": "chronopay-core",
                "status": "READY",
                "port": PORT
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), BackendHandler)
    server.serve_forever()
