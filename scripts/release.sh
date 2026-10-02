#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--publish]"
  echo "Without --publish, uploads a package candidate and its documentation."
  echo "With --publish, uploads a published release."
}

publish_flag=()
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 1
fi
case "${1:-}" in
  "") ;;
  --publish) publish_flag=(--publish) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac

cd -- "$(dirname -- "$0")/.."

read -r -p "Username: " username
read -r -s -p "Password: " password
echo ""

rm -f dist-newstyle/geometry-simple-[0-9]*-docs.tar.gz
rm -f dist-newstyle/sdist/geometry-simple-[0-9]*.tar.gz
cabal haddock --haddock-for-hackage geometry-simple
cabal sdist geometry-simple

cabal upload "${publish_flag[@]}" -u "$username" -p "$password" dist-newstyle/sdist/geometry-simple-[0-9]*.tar.gz
cabal upload "${publish_flag[@]}" -d -u "$username" -p "$password" dist-newstyle/geometry-simple-[0-9]*-docs.tar.gz
