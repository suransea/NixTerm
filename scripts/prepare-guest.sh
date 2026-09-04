#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --guest nixos|freebsd\n' "${0##*/}" >&2
}

guest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --guest)
      guest="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$guest" in
  nixos|freebsd) ;;
  *) usage; exit 2 ;;
esac

result=$(nix build ".#${guest}-guest" --no-link --print-out-paths)
mkdir -p Resources/Guest
rm -rf Resources/Guest/*
cp -a "$result"/. Resources/Guest/
