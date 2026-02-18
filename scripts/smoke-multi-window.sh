#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devilwm-smoke-multi.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR"' EXIT INT TERM

EXPECTED_WINDOWS="${EXPECTED_WINDOWS:-4}"
MARK_FILE="$SMOKE_DIR/apps.mark"
LOG_DIR="$SMOKE_DIR/logs"
TIMEOUT_SEC="${SMOKE_TIMEOUT_SEC:-14}"

STATUS=0
if command -v timeout >/dev/null 2>&1; then
  timeout "$TIMEOUT_SEC" \
    env APP_COUNT="$EXPECTED_WINDOWS" APP_STAGGER_SEC=0.25 APP_MARK_FILE="$MARK_FILE" LOG_DIR="$LOG_DIR" \
    "$ROOT_DIR/scripts/test-in-hyprland.sh" || STATUS=$?
else
  env APP_COUNT="$EXPECTED_WINDOWS" APP_STAGGER_SEC=0.25 APP_MARK_FILE="$MARK_FILE" LOG_DIR="$LOG_DIR" \
    "$ROOT_DIR/scripts/test-in-hyprland.sh" || STATUS=$?
fi

if [ "$STATUS" -ne 0 ] && [ "$STATUS" -ne 124 ]; then
  echo "error: nested test exited with status $STATUS" >&2
fi

RUN_DIR="$(ls -1dt "$LOG_DIR"/* 2>/dev/null | head -n1 || true)"
if [ -z "$RUN_DIR" ]; then
  echo "error: no run logs produced in $LOG_DIR" >&2
  exit 1
fi

STARTED=0
if [ -f "$MARK_FILE" ]; then
  STARTED="$(wc -l < "$MARK_FILE" | tr -d ' ')"
fi
if [ "${STARTED:-0}" -lt "$EXPECTED_WINDOWS" ]; then
  echo "error: multi-window smoke failed; expected >=$EXPECTED_WINDOWS started apps, got $STARTED" >&2
  echo "check logs: $RUN_DIR" >&2
  exit 1
fi

echo "multi-window smoke passed (started=$STARTED, expected=$EXPECTED_WINDOWS, logs=$RUN_DIR)"
