#!/usr/bin/env bash
# Called by dunst `script =` rule. Forwards notification to Aerie.
# Env from dunst: DUNST_APP_NAME DUNST_SUMMARY DUNST_BODY
set -uo pipefail
PORT="${AERIE_EVENT_PORT:-42420}"
export AERIE_PORT="$PORT"
python3 - <<'PY'
import json, os, socket
app = os.environ.get("DUNST_APP_NAME", "unknown")
title = os.environ.get("DUNST_SUMMARY", "")
body = os.environ.get("DUNST_BODY", "")
port = int(os.environ.get("AERIE_PORT", "42420"))
line = json.dumps({"app": app, "title": title, "body": body})
try:
    with open("/tmp/aerie-events.jsonl", "a", encoding="utf-8") as f:
        f.write(line + "\n")
except OSError:
    pass
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=1.0)
    s.sendall((line + "\n").encode("utf-8"))
    s.close()
except OSError:
    pass
PY
