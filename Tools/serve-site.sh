#!/bin/zsh
# Local preview of the website: http://localhost:8080
cd "$(dirname "$0")/../site" && exec python3 -m http.server "${1:-8080}"
