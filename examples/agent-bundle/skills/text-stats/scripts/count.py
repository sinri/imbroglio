import json
import sys

payload = json.load(sys.stdin)
text = payload["text"]
if not isinstance(text, str):
    raise ValueError("text must be a string")
print(json.dumps({"characters": len(text), "lines": len(text.splitlines())}))
