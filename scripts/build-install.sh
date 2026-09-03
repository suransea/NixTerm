#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: nix run .#build-install -- --team-id TEAM --bundle-id ID --device DEVICE_ID\n' >&2
}

team_id=""
bundle_id="dev.nixterm.app"
device_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team-id)
      team_id="${2:-}"
      shift 2
      ;;
    --bundle-id)
      bundle_id="${2:-}"
      shift 2
      ;;
    --device)
      device_id="${2:-}"
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Building and signing an iOS app requires macOS with Xcode.\n' >&2
  exit 1
fi
if [[ -z "$team_id" || -z "$device_id" ]]; then
  usage
  exit 2
fi

if [[ ! -d "${QEMU_FRAMEWORKS:-.build/QEMU/Frameworks}" ]]; then
  printf 'QEMU frameworks are missing. Set QEMU_FRAMEWORKS or populate .build/QEMU/Frameworks.\n' >&2
  exit 1
fi
if [[ -n "${GUEST_BUNDLE:-}" ]]; then
  mkdir -p Resources/Guest
  rm -f Resources/Guest/initramfs.cpio.gz Resources/Guest/initramfs.cpio.lz4
  install -m 0644 "$GUEST_BUNDLE/Image" Resources/Guest/Image
  install -m 0644 "$GUEST_BUNDLE/initramfs.cpio" Resources/Guest/initramfs.cpio
  install -m 0644 "$GUEST_BUNDLE/root.squashfs" Resources/Guest/root.squashfs
fi
if [[ ! -s Resources/Guest/Image || ! -s Resources/Guest/initramfs.cpio || ! -s Resources/Guest/root.squashfs ]]; then
  printf 'Guest resources are missing. Run nix run .#prepare-guest first.\n' >&2
  exit 1
fi
xcodegen generate

derived_data="$PWD/.build/DerivedData"
build_prefix=()
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  if ! sudo -n true 2>/dev/null; then
    printf 'Remote signing requires passwordless sudo to enter the active macOS GUI session.\n' >&2
    exit 1
  fi
  build_prefix=(sudo -n launchctl asuser "$(id -u)" sudo -u "$(id -un)")
fi

build_environment=(env)
for variable in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
  if [[ -n "${!variable:-}" ]]; then
    build_environment+=("$variable=${!variable}")
  fi
done

"${build_prefix[@]}" "${build_environment[@]}" xcodebuild \
  -project NixTerm.xcodeproj \
  -scheme NixTerm \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$derived_data" \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$team_id" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  CODE_SIGN_STYLE=Automatic \
  build | xcbeautify

app_path="$derived_data/Build/Products/Debug-iphoneos/NixTerm.app"
xcrun devicectl device install app --device "$device_id" "$app_path"
