#!/usr/bin/env bash
set -euo pipefail
if pgrep -x haproxy > /dev/null; then
    exit 0
fi
exit 1
