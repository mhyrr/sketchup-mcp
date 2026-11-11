import socket
import threading
import json
from unittest.mock import MagicMock
from sketchup_mcp.server import eval_ruby

def run_mock_server():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 9876))
    server.listen(1)
    conn, _ = server.accept()
    data = conn.recv(1024)
    # JSON-RPC standard response with result payload
    response_payload = {
        "jsonrpc": "2.0",
        "id": "test-1",
        "result": {
            "content": [{"text": "mocked ruby execution"}]
        }
    }
    conn.sendall(json.dumps(response_payload).encode('utf-8') + b'\n')
    conn.close()
    server.close()

def main():
    t = threading.Thread(target=run_mock_server, daemon=True)
    t.start()
    import time; time.sleep(0.1)
    mock_ctx = MagicMock()
    mock_ctx.request_id = "test-1"
    raw_res = eval_ruby(mock_ctx, "puts 'hello from sketchup'")
    print(f"Mock test raw return: {raw_res}")
    data = json.loads(raw_res)
    assert data["success"] is True
    assert data["result"] == "mocked ruby execution"
    print("Success path smoke test passed cleanly!")

if __name__ == "__main__":
    main()
