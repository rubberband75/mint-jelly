#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-datagrip-tests.XXXXXXXX")"

cleanup_test() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "$PROJECT_ROOT/installers/datagrip/run.sh"

cat >"$TEST_ROOT/releases.json" <<'JSON'
{
  "DG": [{
    "type": "release",
    "version": "1.2.3",
    "downloads": {
      "linux": {
        "link": "https://download.jetbrains.com/datagrip/datagrip-1.2.3.tar.gz",
        "checksumLink": "https://download.jetbrains.com/datagrip/datagrip-1.2.3.tar.gz.sha256",
        "size": 123456
      }
    }
  }]
}
JSON

expected_release=$'1.2.3\nhttps://download.jetbrains.com/datagrip/datagrip-1.2.3.tar.gz\nhttps://download.jetbrains.com/datagrip/datagrip-1.2.3.tar.gz.sha256\n123456'
[[ "$(parse_release_metadata "$TEST_ROOT/releases.json")" == "$expected_release" ]] \
  || fail 'DataGrip release metadata parser rejected a valid release.'

printf '%s *%s\n' \
  '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  'datagrip-1.2.3.tar.gz' >"$TEST_ROOT/checksum"
[[ "$(read_checksum "$TEST_ROOT/checksum" 'datagrip-1.2.3.tar.gz')" \
  == '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' ]] \
  || fail 'DataGrip checksum parser rejected a valid checksum.'
if read_checksum "$TEST_ROOT/checksum" 'wrong-name.tar.gz' >/dev/null 2>&1; then
  fail 'DataGrip checksum parser accepted the wrong archive filename.'
fi

mkdir -p "$TEST_ROOT/source/DataGrip-1.2.3/bin" \
  "$TEST_ROOT/source/DataGrip-1.2.3/jbr/bin" "$TEST_ROOT/extracted"
cat >"$TEST_ROOT/source/DataGrip-1.2.3/product-info.json" <<'JSON'
{
  "name": "DataGrip",
  "version": "1.2.3",
  "buildNumber": "123.456",
  "productCode": "DB",
  "productVendor": "JetBrains",
  "svgIconPath": "bin/datagrip.svg",
  "launch": [{
    "os": "Linux",
    "arch": "amd64",
    "launcherPath": "bin/datagrip",
    "javaExecutablePath": "jbr/bin/java",
    "startupWmClass": "jetbrains-datagrip"
  }]
}
JSON
printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_ROOT/source/DataGrip-1.2.3/bin/datagrip"
chmod 0755 "$TEST_ROOT/source/DataGrip-1.2.3/bin/datagrip"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_ROOT/source/DataGrip-1.2.3/jbr/bin/java"
chmod 0755 "$TEST_ROOT/source/DataGrip-1.2.3/jbr/bin/java"
printf '<svg/>\n' >"$TEST_ROOT/source/DataGrip-1.2.3/bin/datagrip.svg"
tar -czf "$TEST_ROOT/good.tar.gz" -C "$TEST_ROOT/source" DataGrip-1.2.3
extract_validated_archive \
  "$TEST_ROOT/good.tar.gz" "$TEST_ROOT/extracted" 'DataGrip-1.2.3' \
  || fail 'DataGrip archive validator rejected a valid archive.'
[[ -x "$TEST_ROOT/extracted/DataGrip-1.2.3/bin/datagrip" ]] \
  || fail 'DataGrip archive extraction lost the launcher.'

mkdir -p "$TEST_ROOT/unsafe/DataGrip-1.2.3/bin" "$TEST_ROOT/unsafe-output"
ln -s ../../../outside "$TEST_ROOT/unsafe/DataGrip-1.2.3/bin/escape"
tar -czf "$TEST_ROOT/unsafe.tar.gz" -C "$TEST_ROOT/unsafe" DataGrip-1.2.3
if extract_validated_archive \
  "$TEST_ROOT/unsafe.tar.gz" "$TEST_ROOT/unsafe-output" 'DataGrip-1.2.3' \
  >/dev/null 2>&1; then
  fail 'DataGrip archive validator accepted an escaping symbolic link.'
fi

printf 'DataGrip installer tests passed.\n'
