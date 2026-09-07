#!/usr/bin/env bash
# Pi quota footer public-interface, SDK, and terminal rendering regressions.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v node >/dev/null 2>&1 || { echo 'skip: node not found'; exit 0; }
command -v npm >/dev/null 2>&1 || { echo 'skip: npm not found'; exit 0; }
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo 'skip: installed Pi package not found'; exit 0; }
TEST_DIR=$(fm_test_tmproot fm-pi-status)
mkdir -p "$TEST_DIR/.pi/extensions" "$TEST_DIR/node_modules/@earendil-works" "$TEST_DIR/bin" "$TEST_DIR/config"
cp "$ROOT/.pi/extensions/fm-primary-status.ts" "$ROOT/.pi/extensions/fm-calm.ts" "$TEST_DIR/.pi/extensions/"
cp -R "$ROOT/.pi/extensions/lib" "$TEST_DIR/.pi/extensions/lib"
cp "$ROOT/tests/fm-pi-status.test.mjs" "$TEST_DIR/test.mjs"
ln -s "$PI_PACKAGE_DIR" "$TEST_DIR/node_modules/@earendil-works/pi-coding-agent"
for package in pi-ai pi-tui; do
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/$package" "$TEST_DIR/node_modules/@earendil-works/$package"
done
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TEST_DIR/node_modules/typebox"
ln -s "$PI_PACKAGE_DIR/node_modules/jiti" "$TEST_DIR/node_modules/jiti"
printf '%s\n' '{"type":"module"}' > "$TEST_DIR/package.json"
FM_HOME="$TEST_DIR" FM_CONFIG_OVERRIDE="$TEST_DIR/config" PI_CODING_AGENT_DIR="$TEST_DIR/agent" PI_OFFLINE=1 PI_TELEMETRY=0 NODE_NO_WARNINGS=1 \
  node "$TEST_DIR/test.mjs"
