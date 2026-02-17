#!/bin/sh
set -eu

DEVILWM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "$DEVILWM_DIR/.." && pwd)"
RIVER_DIR="${RIVER_DIR:-$WORKSPACE_DIR/river}"
WALLPAPER_FILE="${WALLPAPER_FILE:-$DEVILWM_DIR/assets/default-wallpaper.svg}"
RIVER_BIN="$RIVER_DIR/zig-out/bin/river"
DEVILWM_BIN="$DEVILWM_DIR/zig-out/bin/devilwm"

if [ ! -d "$RIVER_DIR" ]; then
  echo "error: river directory not found at $RIVER_DIR" >&2
  exit 1
fi

if [ ! -d "$DEVILWM_DIR" ]; then
  echo "error: devilwm directory not found at $DEVILWM_DIR" >&2
  exit 1
fi

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "==> building river"
  (cd "$RIVER_DIR" && zig build -Dman-pages=false)
  echo "==> building devilwm"
  (cd "$DEVILWM_DIR" && zig build)
fi

if [ ! -x "$RIVER_BIN" ]; then
  echo "error: river binary missing: $RIVER_BIN" >&2
  exit 1
fi

if [ ! -x "$DEVILWM_BIN" ]; then
  echo "error: devilwm binary missing: $DEVILWM_BIN" >&2
  exit 1
fi

pick_term() {
  for t in foot kitty alacritty wezterm xterm; do
    if command -v "$t" >/dev/null 2>&1; then
      printf "%s" "$t"
      return 0
    fi
  done
  return 1
}

TERM_CMD="$(pick_term || true)"
if [ -z "$TERM_CMD" ]; then
  echo "error: no supported terminal found (foot/kitty/alacritty/wezterm/xterm)" >&2
  exit 1
fi

APP_COUNT="${APP_COUNT:-4}"
APP_STAGGER_SEC="${APP_STAGGER_SEC:-0.25}"

default_app_cmd() {
  cat <<EOF
sh -lc 'i=0; while [ "\$i" -lt "$APP_COUNT" ]; do "$TERM_CMD" >/dev/null 2>&1 & i=\$((i+1)); sleep "$APP_STAGGER_SEC"; done'
EOF
}

APP_CMD="${APP_CMD:-$(default_app_cmd)}"
default_wallpaper_cmd() {
  if command -v swaybg >/dev/null 2>&1 && [ -f "$WALLPAPER_FILE" ]; then
    cat <<EOF
swaybg -i "$WALLPAPER_FILE" -m fill >/dev/null 2>&1 &
EOF
    return 0
  fi
  printf ":"
}

WALLPAPER_CMD="${WALLPAPER_CMD:-$(default_wallpaper_cmd)}"
LOG_DIR="${LOG_DIR:-$DEVILWM_DIR/logs}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_LOG_DIR="$LOG_DIR/$RUN_ID"
DEVILWM_LOG="$RUN_LOG_DIR/devilwm.log"
RIVER_LOG="$RUN_LOG_DIR/river.log"

# Keep per-run logs to simplify protocol debugging.
mkdir -p "$RUN_LOG_DIR"

echo "==> starting nested river inside current Wayland session"
echo "    river:   $RIVER_BIN"
echo "    devilwm: $DEVILWM_BIN"
echo "    app:     $APP_CMD"
echo "    wallpaper: $WALLPAPER_FILE"
echo "    app_count(default): $APP_COUNT"
echo "    renderer: vulkan (forced)"
echo "    logs:    $RUN_LOG_DIR"

exec env WLR_BACKENDS=wayland \
  WLR_RENDERER=vulkan \
  "$RIVER_BIN" \
  -c "$DEVILWM_BIN >\"$DEVILWM_LOG\" 2>&1 & $WALLPAPER_CMD $APP_CMD" \
  >"$RIVER_LOG" 2>&1
