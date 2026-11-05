#!/usr/bin/env bash

# The scripts now live in scripts/core and scripts/others. This file stays so
# older guides and links keep working: it swaps itself for the real script,
# in the same place, and runs it.

set -euo pipefail

url="https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/${AIOS_BRANCH:-main}/scripts/core/setup-aiostreams.sh"
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if ! curl -fsSL "$url" -o "$self.new" || ! grep -q 'SELF_SCRIPT_PATH' "$self.new"; then
    rm -f -- "$self.new"
    echo "Couldn't download $url" >&2
    echo "Check the server's connection and that you ran this with sudo, then try again." >&2
    exit 1
fi
chmod 755 "$self.new"
mv -f -- "$self.new" "$self"
exec bash "$self" "$@"
