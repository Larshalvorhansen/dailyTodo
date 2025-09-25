#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || {
  echo "Missing required command: $1" >&2
  exit 1
}; }

need_cmd yabai
need_cmd open
# jq optional; we'll fall back to awk if it's not present.
have_jq() { command -v jq >/dev/null 2>&1; }

# ---------- basic sanity ----------
wait_for_yabai() {
  local tries=20
  while [ $tries -gt 0 ]; do
    if yabai -m query --spaces >/dev/null 2>&1; then return 0; fi
    sleep 0.2
    tries=$((tries - 1))
  done
  return 1
}

if ! wait_for_yabai; then
  echo "yabai did not respond. Is the daemon running and have you granted accessibility permissions?" >&2
  exit 1
fi

# ---------- helpers ----------
spaces_count() {
  local out
  out="$(yabai -m query --spaces 2>/dev/null || true)"
  if [ -z "${out}" ]; then
    echo 0
    return
  fi
  if have_jq; then
    printf "%s" "$out" | jq 'length'
  else
    printf "%s\n" "$out" | awk '/"index":/{c++} END{print c+0}'
  fi
}

ensure_spaces() {
  local want="$1"
  local have
  have="$(spaces_count)"
  while [ "$have" -lt "$want" ]; do
    yabai -m space --create >/dev/null 2>&1 || true
    have=$((have + 1))
    sleep 0.1
  done
}

# idempotent rule add (force managed tiling)
add_rule() {
  local label="$1" match="$2" space="$3"
  if yabai -m rule --list | grep -q "\"label\": \"$label\""; then
    yabai -m rule --remove "$label" >/dev/null 2>&1 || true
  fi
  yabai -m rule --add label="$label" app="$match" space="$space" manage=on >/dev/null 2>&1 || true
}

launch_app() {
  local app="$1"
  if ! pgrep -f "/Applications/.*${app}.*.app/Contents/MacOS" >/dev/null 2>&1 &&
    ! pgrep -x "$app" >/dev/null 2>&1; then
    log "Launching $app"
    open -na "$app" >/dev/null 2>&1 || true
  fi
}

# List window ids for an app regex (space-separated)
list_window_ids_for_app() {
  local app_regex="$1"
  local out
  out="$(yabai -m query --windows 2>/dev/null || true)"
  [ -z "$out" ] && {
    echo ""
    return
  }
  if have_jq; then
    printf "%s" "$out" | jq -r --arg re "$app_regex" '.[] | select(.app|test($re)) | .id' | xargs || true
  else
    # awk fallback: pair "id" with next "app"
    printf "%s\n" "$out" | awk -v re="$app_regex" '
      /"id":[0-9]+/ { id=$0; sub(/.*"id":/,"",id); sub(/[^0-9].*/,"",id) }
      /"app":/ {
        app=$0; gsub(/.*"app":"|".*/,"",app);
        if (app ~ re) print id;
      }' | xargs || true
  fi
}

win_space() {
  local wid="$1"
  local out
  out="$(yabai -m query --windows --window "$wid" 2>/dev/null || true)"
  [ -z "$out" ] && {
    echo 0
    return
  }
  if have_jq; then
    printf "%s" "$out" | jq -r '.space // 0'
  else
    printf "%s\n" "$out" | awk -F: '/"space"[[:space:]]*:/{gsub(/[, ]/,"",$2); print $2; exit}'
  fi
}

wait_for_windows() {
  local app_regex="$1" need="$2" timeout_s="$3"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    local ids count=0
    ids="$(list_window_ids_for_app "$app_regex")"
    for _ in $ids; do count=$((count + 1)); done
    if [ "$count" -ge "$need" ]; then return 0; fi
    sleep 0.3
    elapsed=$((elapsed + 1))
  done
  return 1
}

move_app_to_space() {
  local app_regex="$1" space="$2"
  local ids
  ids="$(list_window_ids_for_app "$app_regex")"
  for wid in $ids; do
    local cur
    cur="$(win_space "$wid")"
    if [ "${cur:-0}" -ne "$space" ]; then
      log "Moving window $wid ($app_regex) to space $space"
      yabai -m window "$wid" --space "$space" >/dev/null 2>&1 || true
    fi
  done
}

focus_space() { yabai -m space --focus "$1" >/dev/null 2>&1 || true; }

balance_space() {
  focus_space "$1"
  yabai -m space --balance >/dev/null 2>&1 || true
}

set_space_layout() {
  local space="$1" layout="${2:-bsp}"
  yabai -m space "$space" --layout "$layout" >/dev/null 2>&1 || true
}

fill_all_spaces() {
  # Set layout to bsp and balance after moves, so windows fill each desktop
  for s in 1 2 3 4 5 6; do
    set_space_layout "$s" bsp
    balance_space "$s"
  done
}

# Focus and arrange windows on a specific space
arrange_space_windows() {
  local space="$1"
  focus_space "$space"
  sleep 0.1
  yabai -m space --balance >/dev/null 2>&1 || true
}

# ---------- desired layout ----------
# 1: Alacritty
# 2: Firefox + ChatGPT
# 3: Kitty + Zotero (side-by-side)
# 4: Messages + Messenger
# 5: Todoist + Safari
# 6: Spotify

log "Ensuring at least 6 spaces…"
ensure_spaces 6

log "Adding rules…"
add_rule "alacritty_to_1" '^Alacritty$' 1
add_rule "firefox_to_2" '^Firefox$' 2
add_rule "chatgpt_to_2" '^ChatGPT$' 2
add_rule "kitty_to_3" '^kitty$' 3
add_rule "zotero_to_3" '^Zotero$' 3
# add_rule "element_to_3" '^Element( Nightly)?$' 3   # <- still commented out
add_rule "messages_to_4" '^Messages$' 4
add_rule "messenger_to_4" '^(Messenger|Facebook Messenger)$' 4
add_rule "todoist_to_5" '^Todoist$' 5
add_rule "safari_to_5" '^Safari$' 5
add_rule "spotify_to_6" '^Spotify$' 6

log "Launching apps (if needed)…"
launch_app "Alacritty"
launch_app "Firefox"
launch_app "ChatGPT"
launch_app "kitty"  # lowercase to match the rule
launch_app "Zotero"
# launch_app "Element"   # <- still commented out
launch_app "Messages"
launch_app "Messenger" || true
launch_app "Todoist"
launch_app "Safari"
launch_app "Spotify"

sleep 0.3

log "Moving existing windows to target spaces…"
move_app_to_space '^Alacritty$' 1
move_app_to_space '^Firefox$' 2
move_app_to_space '^ChatGPT$' 2
move_app_to_space '^kitty$' 3  # lowercase to match actual app name
move_app_to_space '^Zotero$' 3
# move_app_to_space '^Element( Nightly)?$' 3   # <- still commented out
move_app_to_space '^Messages$' 4
move_app_to_space '^(Messenger|Facebook Messenger)$' 4
move_app_to_space '^Todoist$' 5
move_app_to_space '^Safari$' 5
move_app_to_space '^Spotify$' 6

# If Firefox still not on 2, brute-force hop (guarded)
FFID="$(list_window_ids_for_app '^Firefox$' | awk '{print $1}')"
if [ -n "${FFID:-}" ]; then
  cur_space="$(win_space "$FFID")"
  if [ "${cur_space:-0}" -ne 2 ]; then
    log "Firefox not on Desktop 2; hopping with --space next (guarded)…"
    yabai -m window --focus "$FFID" >/dev/null 2>&1 || true
    guard=8
    while [ "$(win_space "$FFID")" -ne 2 ] && [ $guard -gt 0 ]; do
      yabai -m window "$FFID" --space next >/dev/null 2>&1 || true
      sleep 0.1
      guard=$((guard - 1))
    done
  fi
fi

# If Kitty still not on 3, brute-force move it
KITTYID="$(list_window_ids_for_app '^kitty$' | awk '{print $1}')"
if [ -n "${KITTYID:-}" ]; then
  cur_space="$(win_space "$KITTYID")"
  if [ "${cur_space:-0}" -ne 3 ]; then
    log "Kitty not on Desktop 3; forcing move…"
    yabai -m window "$KITTYID" --space 3 >/dev/null 2>&1 || true
    sleep 0.1
  fi
fi

# Kitty + Zotero side-by-side on 3 (reduced wait time ~2 seconds)
if wait_for_windows '^kitty
  log "Arranging Desktop 3 (Kitty + Zotero)…"
  arrange_space_windows 3
fi

# Arrange Messages + Messenger on Desktop 4
if wait_for_windows '^Messages
  log "Arranging Desktop 4 (Messages + Messenger)…"
  arrange_space_windows 4
  # Focus Messenger if it exists to bring it forward
  MSGID="$(list_window_ids_for_app '^(Messenger|Facebook Messenger)$' | awk '{print $1}')"
  if [ -n "${MSGID:-}" ]; then
    yabai -m window --focus "$MSGID" >/dev/null 2>&1 || true
    sleep 0.1
  fi
fi

# Ensure all workspaces are bsp + balanced so tiles fill the screen
fill_all_spaces

# Focus Desktop 1 at the end
log "Focusing Desktop 1…"
focus_space 1

log "All set 🎯"
echo "Layout applied. Rules in place so new windows open on the right desktops." 1 7 && wait_for_windows '^Zotero
  log "Arranging Desktop 3 (Kitty + Zotero)…"
  arrange_space_windows 3
fi

# Arrange Messages + Messenger on Desktop 4
if wait_for_windows '^Messages$' 1 23; then
  log "Arranging Desktop 4 (Messages + Messenger)…"
  arrange_space_windows 4
  # Focus Messenger if it exists to bring it forward
  MSGID="$(list_window_ids_for_app '^(Messenger|Facebook Messenger)$' | awk '{print $1}')"
  if [ -n "${MSGID:-}" ]; then
    yabai -m window --focus "$MSGID" >/dev/null 2>&1 || true
    sleep 0.2
  fi
fi

# Ensure all workspaces are bsp + balanced so tiles fill the screen
fill_all_spaces

# Focus Desktop 1 at the end
log "Focusing Desktop 1…"
focus_space 1

log "All set 🎯"
echo "Layout applied. Rules in place so new windows open on the right desktops." 1 7; then
  log "Arranging Desktop 3 (Kitty + Zotero)…"
  arrange_space_windows 3
fi

# Arrange Messages + Messenger on Desktop 4
if wait_for_windows '^Messages$' 1 23; then
  log "Arranging Desktop 4 (Messages + Messenger)…"
  arrange_space_windows 4
  # Focus Messenger if it exists to bring it forward
  MSGID="$(list_window_ids_for_app '^(Messenger|Facebook Messenger)$' | awk '{print $1}')"
  if [ -n "${MSGID:-}" ]; then
    yabai -m window --focus "$MSGID" >/dev/null 2>&1 || true
    sleep 0.2
  fi
fi

# Ensure all workspaces are bsp + balanced so tiles fill the screen
fill_all_spaces

# Focus Desktop 1 at the end
log "Focusing Desktop 1…"
focus_space 1

log "All set 🎯"
echo "Layout applied. Rules in place so new windows open on the right desktops." 1 7; then
  log "Arranging Desktop 4 (Messages + Messenger)…"
  arrange_space_windows 4
  # Focus Messenger if it exists to bring it forward
  MSGID="$(list_window_ids_for_app '^(Messenger|Facebook Messenger)$' | awk '{print $1}')"
  if [ -n "${MSGID:-}" ]; then
    yabai -m window --focus "$MSGID" >/dev/null 2>&1 || true
    sleep 0.2
  fi
fi

# Ensure all workspaces are bsp + balanced so tiles fill the screen
fill_all_spaces

# Focus Desktop 1 at the end
log "Focusing Desktop 1…"
focus_space 1

log "All set 🎯"
echo "Layout applied. Rules in place so new windows open on the right desktops." 1 7 && wait_for_windows '^Zotero
  log "Arranging Desktop 3 (Kitty + Zotero)…"
  arrange_space_windows 3
fi

# Arrange Messages + Messenger on Desktop 4
if wait_for_windows '^Messages$' 1 23; then
  log "Arranging Desktop 4 (Messages + Messenger)…"
  arrange_space_windows 4
  # Focus Messenger if it exists to bring it forward
  MSGID="$(list_window_ids_for_app '^(Messenger|Facebook Messenger)$' | awk '{print $1}')"
  if [ -n "${MSGID:-}" ]; then
    yabai -m window --focus "$MSGID" >/dev/null 2>&1 || true
    sleep 0.2
  fi
fi

# Ensure all workspaces are bsp + balanced so tiles fill the screen
fill_all_spaces

# Focus Desktop 1 at the end
log "Focusing Desktop 1…"
focus_space 1

log "All set 🎯"
echo "Layout applied. Rules in place so new windows open on the right desktops." 1 7; then
  log "Arranging Desktop 3 (Kitty + Zotero)…"
  arrange_space_windows 3
fi

# Arrange Messages + Messenger on Desktop 4
if wait_for_windows '^Messages$' 1 23; then
  log "Arranging Desktop 4 (Messages + Messenger)…"
  arrange_space_windows 4
  # Focus Messenger if it exists to bring it forward
  MSGID="$(list_window_ids_for_app '^(Messenger|Facebook Messenger)$' | awk '{print $1}')"
  if [ -n "${MSGID:-}" ]; then
    yabai -m window --focus "$MSGID" >/dev/null 2>&1 || true
    sleep 0.2
  fi
fi

# Ensure all workspaces are bsp + balanced so tiles fill the screen
fill_all_spaces

# Focus Desktop 1 at the end
log "Focusing Desktop 1…"
focus_space 1

log "All set 🎯"
echo "Layout applied. Rules in place so new windows open on the right desktops."
