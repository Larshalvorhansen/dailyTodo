#!/bin/bash

# Function to check if an app is running
is_running() {
  osascript -e "tell application \"System Events\" to exists process \"$1\""
}

# Function to launch an app if not running
launch_app() {
  local app="$1"
  if [ "$(is_running "$app")" = "false" ]; then
    open -a "$app" &
  fi
}

# Function to wait for an app's windows to appear
wait_for_app_windows() {
  local app="$1"
  local timeout=10
  local start
  start=$(date +%s)
  while [ "$(date +%s)" -lt "$((start + timeout))" ]; do
    if [ -n "$(get_window_ids "$app")" ]; then
      return 0
    fi
    sleep 0.2
  done
  echo "Timeout waiting for $app windows" >&2
  return 1
}

# Function to get window IDs for an app using python3 (no jq required)
get_window_ids() {
  local app="$1"
  yabai -m query --windows | /usr/bin/python3 -c "
import sys, json
data = json.load(sys.stdin)
ids = [str(w['id']) for w in data if w['app'] == '$app']
print(' '.join(ids))
"
}

# Function to move all windows of an app to a specific space
move_app_to_space() {
  local app="$1"
  local space="$2"
  launch_app "$app"
  wait_for_app_windows "$app" || true # Continue even on timeout
  local ids
  ids=$(get_window_ids "$app")
  for wid in $ids; do
    yabai -m window "$wid" --space "$space" 2>/dev/null || true
  done
}

# Function to add or update a yabai rule for an app
add_rule() {
  local app="$1"
  local space="$2"
  local label="autosetup_${app// /_}"
  yabai -m rule --remove "$label" 2>/dev/null || true
  yabai -m rule --add label="$label" app="^$app$" space="$space" manage=on 2>/dev/null || true
}

# Create spaces if fewer than 6 exist
num_spaces=$(yabai -m query --spaces | /usr/bin/python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
while [ "$num_spaces" -lt 6 ]; do
  yabai -m space --create
  num_spaces=$((num_spaces + 1))
done

# Set BSP layout for all 6 spaces
for i in {1..6}; do
  yabai -m space "$i" --layout bsp 2>/dev/null || true
done

# Add rules for all apps
add_rule "Alacritty" 1
add_rule "Firefox" 2
add_rule "ChatGPT" 2
add_rule "Kitty" 3
add_rule "Zotero" 3
add_rule "Messages" 4
add_rule "Messenger" 4
add_rule "Todoist" 5
add_rule "Safari" 5
add_rule "Spotify" 6

# Move apps to their respective spaces
move_app_to_space "Alacritty" 1
move_app_to_space "Firefox" 2
move_app_to_space "ChatGPT" 2
move_app_to_space "Kitty" 3
move_app_to_space "Zotero" 3
move_app_to_space "Messages" 4
move_app_to_space "Messenger" 4
move_app_to_space "Todoist" 5
move_app_to_space "Safari" 5
move_app_to_space "Spotify" 6

# Fix Messenger visibility by focusing it on Desktop 4
yabai -m space --focus 4 2>/dev/null || true
messenger_ids=$(get_window_ids "Messenger")
if [ -n "$messenger_ids" ]; then
  first_id=$(echo "$messenger_ids" | awk '{print $1}')
  yabai -m window --focus "$first_id" 2>/dev/null || true
fi

# End by focusing Desktop 1
yabai -m space --focus 1 2>/dev/null || true
