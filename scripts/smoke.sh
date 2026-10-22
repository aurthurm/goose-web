#!/usr/bin/env sh
set -eu
# Start examples/hello executable separately, then run this script.
curl --fail --silent --show-error http://127.0.0.1:8000/health | grep '"status":"ok"'
curl --fail --silent --show-error http://127.0.0.1:8000/ | grep 'Hello from Goose Web'
echo "Smoke checks passed"
