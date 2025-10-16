#!/bin/bash

# Get app window IDs (fast, single query)
get_window_ids() {
  yabai -m query --windows | /usr/bin/python3 -c "
import sys, json
data = json.load(sys.stdin)
ids = [str(w['id']) for w in data if w['app'] == '$1']
print(' '.join(ids))
"
}

# Launch app only if not running
launch_if_needed() {
  pgrep -x "$1" >/dev/null || open -a "$1" &
}

# Move app windows to space
move_app_to_space() {
  local app="$1" space="$2"
  launch_if_needed "$app"
  sleep 0.05
  local ids=$(get_window_ids "$app")
  for wid in $ids; do
    yabai -m window "$wid" --space "$space" 2>/dev/null &
  done
}

# Add yabai rule
add_rule() {
  local label="autosetup_${1// /_}"
  yabai -m rule --remove "$label" 2>/dev/null
  yabai -m rule --add label="$label" app="^$1$" space="$2" manage=on
}

# Create spaces to reach 6
num_spaces=$(yabai -m query --spaces | /usr/bin/python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
for ((i = num_spaces; i < 6; i++)); do
  yabai -m space --create
done

# Set BSP layout for all spaces in parallel
for i in {1..6}; do
  yabai -m space "$i" --layout bsp 2>/dev/null &
done
wait

# Define app-to-space mapping as parallel arrays
apps=(
  "Alacritty" "Firefox" "Claude" "Kitty" "Zotero"
  "Messages" "Messenger" "Todoist" "Safari" "Spotify"
)
spaces=(1 2 2 3 3 4 4 5 5 6)

# Add all rules
for i in "${!apps[@]}"; do
  add_rule "${apps[$i]}" "${spaces[$i]}"
done

# Launch and move all apps in parallel
for i in "${!apps[@]}"; do
  move_app_to_space "${apps[$i]}" "${spaces[$i]}"
done
wait

# Small delay to let windows settle
sleep 0.3

# Focus Messenger on space 4
yabai -m space --focus 4 2>/dev/null
messenger_ids=$(get_window_ids "Messenger")
[ -n "$messenger_ids" ] && yabai -m window --focus "${messenger_ids%% *}" 2>/dev/null

# End on space 1
yabai -m space --focus 1 2>/dev/null
