import http.server
import json
import sys

NODE_NAME = sys.argv[1]
CFG_PATH = sys.argv[2]

with open(CFG_PATH, "r") as f:
    CFG = json.load(f)

PORT = int(CFG["listen_port"])
WORKER_TOKEN = CFG["worker_token"].strip()
with open(CFG["expected_token_file"], "r") as tf:
    EXPECTED_TOKEN = tf.read().strip()

# First occurrence of MAX_CONNECTIONS wins (simulating strict env parser)
MAX_CONN = 0
with open(CFG["env_file"], "r") as ef:
    for line in ef:
        line = line.strip()
        if line.startswith("MAX_CONNECTIONS="):
            MAX_CONN = int(line.split("=", 1)[1])
            break

class WorkerHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/work":
            if WORKER_TOKEN != EXPECTED_TOKEN:
                body = json.dumps({
                    "node": NODE_NAME,
                    "error": "401_UNAUTHORIZED_JOIN_TOKEN_MISMATCH",
                    "received_token": WORKER_TOKEN
                }).encode("utf-8")
                self.send_response(401)
            elif MAX_CONN <= 0:
                body = json.dumps({
                    "node": NODE_NAME,
                    "error": "503_MAX_CONNECTIONS_ZERO_IN_ENV",
                    "max_connections": MAX_CONN
                }).encode("utf-8")
                self.send_response(503)
            else:
                body = json.dumps({
                    "node": NODE_NAME,
                    "status": "WORKER_HEALTHY",
                    "max_connections": MAX_CONN,
                    "port": PORT
                }).encode("utf-8")
                self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), WorkerHandler)
    server.serve_forever()
