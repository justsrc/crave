#!/usr/bin/env bash

set -eE -o pipefail

ROOT=/tmp/src/android

fail() {
  local rc="$1"
  shift
  printf 'PRECHECK FAILED: %s\n' "$*" >&2
  exit "$rc"
}

sync_sources() {
  local sync_log="$ROOT/evox-resync.log"
  local sync_rc

  printf '[stage] syncing sources; log=%s\n' "$sync_log"
  if /opt/crave/resync.sh 2>&1 | tee "$sync_log"; then
    sync_rc=0
  else
    sync_rc=$?
  fi
  printf '[stage] resync pipeline rc=%s\n' "$sync_rc"
  [[ "$sync_rc" -eq 0 ]] || fail 45 "resync or log capture failed; inspect $sync_log"
  grep -qF 'repo sync has finished successfully.' "$sync_log" || fail 45 \
    "resync returned zero without repo's success message; inspect $sync_log"
}

report_revisions() {
  local path revision
  for path in \
    .repo/manifests \
    .repo/local_manifests \
    build/make \
    build/soong \
    vendor/lineage \
    development \
    external/avb \
    device/xiaomi/laurel_sprout \
    device/xiaomi/sm6125-common \
    hardware/xiaomi \
    kernel/xiaomi/sm6125 \
    vendor/xiaomi/laurel_sprout \
    vendor/xiaomi/sm6125-common \
    vendor/evolution-priv/keys; do
    if revision=$(git --no-pager --no-optional-locks -C "$path" rev-parse HEAD); then
      printf '[revision] %s %s\n' "$path" "$revision"
    else
      printf '[revision] unavailable: %s\n' "$path" >&2
    fi
  done
}

preflight() {
  local path
  for path in \
    build/envsetup.sh \
    build/make/envsetup.sh \
    build/make/core/envsetup.mk \
    build/soong/soong_ui.bash \
    vendor/lineage/build/envsetup.sh \
    vendor/lineage/config/evolution.mk \
    vendor/lineage/release/release_configs/bp4a.textproto \
    device/xiaomi/laurel_sprout/lineage_laurel_sprout.mk \
    device/xiaomi/sm6125-common/common.mk; do
    [[ -f "$path" ]] || fail 41 "missing $path in $ROOT"
  done

  for path in \
    device/xiaomi/laurel_sprout \
    device/xiaomi/sm6125-common \
    hardware/xiaomi \
    kernel/xiaomi/sm6125 \
    vendor/xiaomi/laurel_sprout \
    vendor/xiaomi/sm6125-common; do
    [[ -d "$path" ]] || fail 41 "missing project directory $path"
  done
}

keys_ready() {
  local key_dir=vendor/evolution-priv/keys
  local p src n overrides

  for p in keys.mk Android.bp avb.pk8 avb.x509.pem avb_custom_key.bin \
    testkey.pk8 testkey.x509.pem; do
    if [[ ! -s "$key_dir/$p" ]]; then
      printf '[keys] incomplete: %s\n' "$key_dir/$p" >&2
      return 1
    fi
  done

  for src in build/make/target/product/security/*.pk8; do
    if [[ ! -s "$src" ]]; then
      printf '[keys] missing platform source key: %s\n' "$src" >&2
      return 1
    fi
    n=${src##*/}
    n=${n%.pk8}
    if [[ ! -s "$key_dir/$n.pk8" || ! -s "$key_dir/$n.x509.pem" ]]; then
      printf '[keys] incomplete platform key: %s\n' "$n" >&2
      return 1
    fi
  done


  if ! overrides=$(grep -oE '[^:[:space:]]+\.certificate\.override' \
    "$key_dir/keys.mk" | sort -u); then
    printf '[keys] could not read certificate overrides from keys.mk\n' >&2
    return 1
  fi
  if [[ -z "$overrides" ]]; then
    printf '[keys] keys.mk contains no certificate overrides\n' >&2
    return 1
  fi

  while IFS= read -r n; do
    if [[ ! -s "$key_dir/$n.pk8" || ! -s "$key_dir/$n.x509.pem" ]]; then
      printf '[keys] incomplete override: %s\n' "$n" >&2
      return 1
    fi
  done <<< "$overrides"
  return 0
}

prepare_keys() {
  local keys_rc
  if [[ -e vendor/evolution-priv/keys || -L vendor/evolution-priv/keys ]]; then
    keys_ready || fail 42 \
      'existing signing keys are incomplete; preserve and repair them instead of replacing them'
    printf '[keys] reusing existing complete key set\n'
    return 0
  fi

  [[ -f development/tools/make_key ]] || fail 41 'missing development/tools/make_key'
  [[ -x external/avb/avbtool.py ]] || fail 41 'missing executable external/avb/avbtool.py'

  printf '[keys] generating initial key set\n'
  git clone --depth 1 --branch master \
    https://github.com/Evolution-X/vendor_evolution-priv_keys-template \
    vendor/evolution-priv/keys


  if ( cd "$ROOT/vendor/evolution-priv/keys" && ./keys.sh ); then
    keys_rc=0
  else
    keys_rc=$?
  fi
  printf '[stage] keys.sh rc=%s; checking generated files\n' "$keys_rc"
  keys_ready || fail 42 'key set incomplete after generation; generated files have been preserved'
  printf '[keys] generated key set passed file checks\n'
}

setup_environment() {
  local src_rc lunch_rc
  export USE_CCACHE=false


  set +eE
  set +o pipefail

  source build/envsetup.sh
  src_rc=$?

  export USE_CCACHE=false
  set -eE -o pipefail

  printf '[stage] envsetup rc=%s\n' "$src_rc"
  [[ "$src_rc" -eq 0 ]] || fail 43 'envsetup failed'
  command -v lunch >/dev/null || fail 43 'envsetup did not define lunch'
  command -v m >/dev/null || fail 43 'envsetup did not expose m'

  if lunch lineage_laurel_sprout-bp4a-userdebug; then
    lunch_rc=0
  else
    lunch_rc=$?
  fi
  printf '[stage] lunch rc=%s\n' "$lunch_rc"
  [[ "$lunch_rc" -eq 0 ]] || fail 44 'lunch failed'
  [[ "${TARGET_PRODUCT:-}" == lineage_laurel_sprout && \
    "${TARGET_RELEASE:-}" == bp4a && \
    "${TARGET_BUILD_VARIANT:-}" == userdebug ]] || fail 44 'lunch did not set the expected target'
  export USE_CCACHE=false
}

main() {
  local build_rc
  [[ "$#" -eq 0 ]] || fail 40 'this build-node payload takes no arguments'
  [[ -d "$ROOT/.repo" && -x /opt/crave/resync.sh ]] || fail 40 \
    'expected the queued build-node checkout at /tmp/src/android and its resync helper'
  cd "$ROOT"
  export USE_CCACHE=false

  printf '[stage] updating local manifest\n'
  rm -rf .repo/local_manifests
  git clone --depth 1 --branch main \
    https://github.com/justsrc/local_manifests \
    .repo/local_manifests

  repo init -u https://github.com/Evolution-X/manifest -b bka --depth=1 --git-lfs

  sync_sources

  cd "$ROOT"
  preflight
  prepare_keys
  report_revisions
  setup_environment

  cd "$ROOT"
  printf '[stage] building evolution; USE_CCACHE=%s\n' "$USE_CCACHE"
  if m evolution; then
    build_rc=0
  else
    build_rc=$?
  fi
  printf '[stage] build rc=%s\n' "$build_rc"
  return "$build_rc"
}

main "$@"
