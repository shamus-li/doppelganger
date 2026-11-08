#!/bin/bash
# Copies the libraries sshfs loads from /usr/local and /opt/homebrew into an app's Frameworks folder
# and points sshfs and each other at those copies. Those folders belong to the user, so a library
# there could be swapped for one that runs inside sshfs; the copies are signed with the app.
#
#   sshfs/bundle-libs.sh SSHFS FRAMEWORKS
set -euo pipefail
SSHFS=$1
FRAMEWORKS=$2
mkdir -p "$FRAMEWORKS"

# The non-system libraries a binary links, one path per line.
deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^(/usr/local|/opt/homebrew)/' || true; }

queue=("$SSHFS")
while [ ${#queue[@]} -gt 0 ]; do
	binary=${queue[0]}
	queue=("${queue[@]:1}")
	for lib in $(deps "$binary"); do
		name=$(basename "$lib")
		install_name_tool -change "$lib" "@executable_path/../Frameworks/$name" "$binary" 2>/dev/null
		if [ ! -e "$FRAMEWORKS/$name" ]; then
			cp "$lib" "$FRAMEWORKS/$name"
			chmod u+w "$FRAMEWORKS/$name"
			install_name_tool -id "@executable_path/../Frameworks/$name" "$FRAMEWORKS/$name" 2>/dev/null
			queue+=("$FRAMEWORKS/$name")
		fi
	done
done
