#!/usr/bin/env bash
set -euo pipefail

run_id=33593908499
artifact=Sysroot-ios-tci-arm64
archive_sha256=756c94505d1f4f4c19b1c21f82f9469c390e432504c4d713fe2b3c0b0148c3a7
destination="${1:-.build/QEMU/Frameworks}"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

gh run download "$run_id" --repo utmapp/UTM --name "$artifact" --dir "$temporary_directory"

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256="$(sha256sum "$temporary_directory/sysroot.tgz" | cut -d ' ' -f 1)"
else
  actual_sha256="$(shasum -a 256 "$temporary_directory/sysroot.tgz" | cut -d ' ' -f 1)"
fi
if [[ "$actual_sha256" != "$archive_sha256" ]]; then
  printf 'QEMU sysroot checksum mismatch: %s\n' "$actual_sha256" >&2
  exit 1
fi

mkdir -p "$temporary_directory/sysroot" "$destination"
tar -xzf "$temporary_directory/sysroot.tgz" -C "$temporary_directory/sysroot"
framework_root="$temporary_directory/sysroot/sysroot-ios-tci-arm64/Frameworks"
frameworks=(
  qemu-aarch64-softmmu pixman-1.0 jpeg.62 epoxy.0 gio-2.0.0 gobject-2.0.0
  glib-2.0.0 gmodule-2.0.0 ffi.8 iconv.2 intl.8 zstd.1 slirp.0 spice-server.1
  ssl.1.1 crypto.1.1 opus.0 gstreamer-1.0.0 gstapp-1.0.0 gstbase-1.0.0
  virglrenderer.1 vulkan.1
)
for framework in "${frameworks[@]}"; do
  rm -rf "$destination/$framework.framework"
  cp -R "$framework_root/$framework.framework" "$destination/"
done

printf 'Installed %d signed-at-build-time frameworks in %s\n' "${#frameworks[@]}" "$destination"
