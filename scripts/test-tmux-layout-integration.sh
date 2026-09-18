#!/usr/bin/env bash
# Test an emitted Swift layout against an isolated, config-free tmux server.
set -euo pipefail
layout=${1:?Pass the layout emitted by TmuxLayoutTests}
test_dir=$(mktemp -d)
tmux_test() { tmux -S "$test_dir/socket" "$@"; }
cleanup() {
    tmux_test kill-server 2>/dev/null || true
    rm -rf "$test_dir"
}
trap cleanup EXIT
tmux_test -f /dev/null new-session -d -s equalize -x 203 -y 70 'sleep 120'
tmux_test set-option -g status off
tmux_test set-option -w window-size manual
tmux_test resize-window -x 203 -y 69
for pane in 1 2 3 4 5; do
    tmux_test split-window -d -t equalize:0 'sleep 120'
    tmux_test select-layout -t equalize:0 tiled >/dev/null
done
# tmux assigns the fixture's leaves to the existing panes in traversal order.
tmux_test select-layout -t equalize:0 "$layout" >/dev/null
expected='67x34
67x34
67x34
67x34
67x34
67x34'
actual=$(tmux_test list-panes -t equalize:0 -F '#{pane_width}x#{pane_height}')
[[ "$actual" == "$expected" ]]
before=$(tmux_test display-message -p -t equalize:0 '#{window_layout}')
tmux_test resize-pane -Z -t equalize:0.0
tmux_test resize-pane -Z -t equalize:0.0
after=$(tmux_test display-message -p -t equalize:0 '#{window_layout}')
[[ "$before" == "$after" ]]
# Equalize while zoomed, restoring zoom using the controller's command sequence.
tmux_test resize-pane -Z -t equalize:0.0
tmux_test select-layout -t equalize:0 "$layout" \; resize-pane -Z -t equalize:0.0 >/dev/null
[[ $(tmux_test display-message -p -t equalize:0 '#{window_zoomed_flag}') == 1 ]]
tmux_test resize-pane -Z -t equalize:0.0
[[ $(tmux_test display-message -p -t equalize:0 '#{window_layout}') == "$before" ]]
echo 'tmux layout and zoom round trip passed'
