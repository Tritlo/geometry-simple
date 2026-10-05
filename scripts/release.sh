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

if [ -n "$(git status --porcelain)" ]; then
  echo "Release requires a clean working tree." >&2
  exit 1
fi
remote_head=$(git ls-remote --exit-code origin refs/heads/main)
remote_head=${remote_head%%$'\t'*}
if [ "$(git rev-parse HEAD)" != "$remote_head" ]; then
  echo "Release HEAD must match the pushed origin/main commit." >&2
  exit 1
fi

cabal check
rm -f dist-newstyle/geometry-simple-[0-9]*-docs.tar.gz
rm -f dist-newstyle/sdist/geometry-simple-[0-9]*.tar.gz
cabal haddock --haddock-for-hackage geometry-simple
cabal sdist .
python3 dev/check_sdist.py dist-newstyle/sdist/geometry-simple-[0-9]*.tar.gz

if [ -n "$(git status --porcelain)" ]; then
  echo "Source files changed while preparing the release." >&2
  exit 1
fi

cabal upload ${publish_flag[@]+"${publish_flag[@]}"} dist-newstyle/sdist/geometry-simple-[0-9]*.tar.gz
cabal upload ${publish_flag[@]+"${publish_flag[@]}"} -d dist-newstyle/geometry-simple-[0-9]*-docs.tar.gz
