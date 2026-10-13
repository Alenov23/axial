#!/bin/bash
# Merge an arm64 build and an x86_64 build of Axial into universal binaries.
#
# Usage: tools/make-universal.sh [ARM64_BUILD_DIR] [X86_64_BUILD_DIR] [OUTPUT_DIR]
#
# Defaults:
#   ARM64_BUILD_DIR  ~/Library/Caches/axial-build/native
#   X86_64_BUILD_DIR ~/Library/Caches/axial-build/intel
#   OUTPUT_DIR       ~/Library/Caches/axial-build/universal
#
# Environment:
#   AXIAL_SIGN_IDENTITY  codesign identity (default "-" = ad-hoc), as in CMake.
#
# The arm64 bundles are copied as-is, then every Mach-O inside them is replaced
# by `lipo -create` of the arm64 and x86_64 counterparts. Signing mirrors
# cmake/Bundle.cmake (hardened runtime, inside-out) and cmake/Framework.cmake.
set -euo pipefail

cache="${HOME}/Library/Caches/axial-build"
arm_dir="${1:-${cache}/native}"
x86_dir="${2:-${cache}/intel}"
out_dir="${3:-${cache}/universal}"
identity="${AXIAL_SIGN_IDENTITY:--}"

products=(Axial.app 3DconnexionClient.framework 3DconnexionNavlib.framework)

die() { echo "make-universal: error: $*" >&2; exit 1; }
log() { echo "make-universal: $*"; }

is_macho() { file -b "$1" | grep -q 'Mach-O'; }

has_arch() { # file arch
  local a
  for a in $(lipo -archs "$1"); do [ "$a" = "$2" ] && return 0; done
  return 1
}

for product in "${products[@]}"; do
  [ -d "${arm_dir}/bin/${product}" ] || die "missing ${arm_dir}/bin/${product}"
  [ -d "${x86_dir}/bin/${product}" ] || die "missing ${x86_dir}/bin/${product}"
done

mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd -P)"
case "${out_dir}" in
  /|"${HOME}"|"$(cd "${arm_dir}" && pwd -P)"*|"$(cd "${x86_dir}" && pwd -P)"*)
    die "refusing to use output dir ${out_dir}" ;;
esac

# Bundle-relative paths of all Mach-O files in a bundle (regular files only;
# framework symlinks are carried over by the copy).
macho_list() { # bundle_dir
  (cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    is_macho "$f" && printf '%s\n' "${f#./}"
  done) || true
}

resource_diff() { # arm_bundle x86_bundle product
  local f
  { (cd "$1" && find . -type f ! -path '*/_CodeSignature/*' ! -path '*.dSYM/*' -print)
    (cd "$2" && find . -type f ! -path '*/_CodeSignature/*' ! -path '*.dSYM/*' -print); } |
    LC_ALL=C sort -u | while IFS= read -r f; do
      if [ ! -f "$1/$f" ] || [ ! -f "$2/$f" ]; then
        log "warning: $3: ${f#./} exists only in one build (arm64 bundle used as-is)"
      elif ! is_macho "$1/$f" && ! cmp -s "$1/$f" "$2/$f"; then
        log "warning: $3: ${f#./} differs between builds (arm64 copy kept)"
      fi
    done
}

for product in "${products[@]}"; do
  arm="${arm_dir}/bin/${product}"
  x86="${x86_dir}/bin/${product}"
  dst="${out_dir}/${product}"

  log "assembling ${product}"
  rm -rf "${out_dir:?}/${product:?}"
  ditto "${arm}" "${dst}"

  arm_list="$(macho_list "${arm}")"
  x86_list="$(macho_list "${x86}")"
  if [ "${arm_list}" != "${x86_list}" ]; then
    echo "arm64 Mach-O files:"; echo "${arm_list}" | sed 's/^/  /'
    echo "x86_64 Mach-O files:"; echo "${x86_list}" | sed 's/^/  /'
    die "${product}: arm64 and x86_64 bundles contain different Mach-O files"
  fi

  # Non-code files should be identical; report (but tolerate) differences.
  resource_diff "${arm}" "${x86}" "${product}"

  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    a="${arm}/${rel}"; x="${x86}/${rel}"; o="${dst}/${rel}"
    has_arch "${a}" arm64 || die "${a} has no arm64 slice ($(lipo -archs "${a}"))"
    has_arch "${x}" x86_64 || die "${x} has no x86_64 slice ($(lipo -archs "${x}"))"
    lipo -create "${a}" "${x}" -output "${o}.universal"
    # Preserve permissions of the arm64 copy.
    chmod "$(stat -f '%Lp' "${a}")" "${o}.universal"
    mv -f "${o}.universal" "${o}"
    log "  lipo ${rel}: $(lipo -archs "${o}")"
  done <<< "${arm_list}"
done

# --- signing -----------------------------------------------------------------
sign_runtime() { /usr/bin/codesign --force --options runtime --sign "${identity}" "$1"; }

app="${out_dir}/Axial.app"
helpers="${app}/Contents/Library/Helpers"

# Same order as cmake/Bundle.cmake: nested helper app, loose helpers, main app.
log "signing Axial.app (identity '${identity}')"
for path in "${helpers}/Axial Service.app" "${helpers}/axialctl" "${helpers}/axial-web-setup" "${app}"; do
  [ -e "${path}" ] || die "missing ${path}"
  sign_runtime "${path}"
done

# Same as cmake/Framework.cmake.
for fw in 3DconnexionClient.framework 3DconnexionNavlib.framework; do
  log "signing ${fw}"
  /usr/bin/codesign --force --sign "${identity}" "${out_dir}/${fw}"
done

# --- verification ------------------------------------------------------------
status=0
log "verifying architectures"
for product in "${products[@]}"; do
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    archs="$(lipo -archs "${out_dir}/${product}/${rel}")"
    echo "  ${product}/${rel}: ${archs}"
    if ! has_arch "${out_dir}/${product}/${rel}" arm64 || ! has_arch "${out_dir}/${product}/${rel}" x86_64; then
      echo "  ^ not universal" >&2; status=1
    fi
  done <<< "$(macho_list "${out_dir}/${product}")"
done

log "verifying signatures"
for product in "${products[@]}"; do
  if /usr/bin/codesign --verify --deep --strict --verbose=2 "${out_dir}/${product}"; then :; else status=1; fi
done

[ "${status}" -eq 0 ] || die "verification failed"
log "done: ${out_dir}"
