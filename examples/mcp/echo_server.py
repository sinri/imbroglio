"""Minimal stdio MCP example. Only JSON-RPC is written to stdout."""
import json
import sys

for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue
    method = message.get("method")
    response = {"jsonrpc": "2.0", "id": message["id"]}
    if method == "initialize":
        response["result"] = {
            "protocolVersion": "2025-11-25",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "imbroglio-example", "version": "1.0.0"},
        }
    elif method == "tools/list":
        response["result"] = {"tools": [{
            "name": "echo",
            "description": "返回用户提供的文本，用于验证 MCP 连接。",
            "inputSchema": {
                "type": "object", "properties": {"text": {"type": "string"}},
                "required": ["text"], "additionalProperties": False,
            },
            "annotations": {"readOnlyHint": True},
        }]}
    elif method == "tools/call":
        params = message.get("params", {})
        text = params.get("arguments", {}).get("text")
        valid = params.get("name") == "echo" and isinstance(text, str)
        response["result"] = {
            "content": [{"type": "text", "text": text if valid else "需要 echo 工具与 text 字符串"}],
            "isError": not valid,
        }
    elif method == "ping":
        response["result"] = {}
    else:
        response["error"] = {"code": -32601, "message": "Method not found"}
    print(json.dumps(response, ensure_ascii=False), flush=True)
