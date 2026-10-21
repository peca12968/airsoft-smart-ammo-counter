#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 "$root/scripts/generate_protocol.py" --check
swift test --package-path "$root"
build_root="${AMMO_BUILD_ROOT:-${TMPDIR:-/tmp}/airsoft-verification}"
mkdir -p "$build_root"
xcodebuild -project "$root/AirsoftSmartAmmo.xcodeproj" -scheme AmmoPhone -destination 'generic/platform=iOS' -derivedDataPath "$build_root/Phone" CODE_SIGNING_ALLOWED=NO build > "$build_root/phone.log" 2>&1
xcodebuild -project "$root/AirsoftSmartAmmo.xcodeproj" -scheme AmmoWatch -destination 'generic/platform=watchOS' -derivedDataPath "$build_root/Watch" CODE_SIGNING_ALLOWED=NO build > "$build_root/watch.log" 2>&1
clang++ -std=c++11 -Wall -Wextra -Werror -ffast-math -fsanitize=address,undefined "$root/firmware/tests/vibration_tests.cpp" -o "$build_root/vibration_tests"
"$build_root/vibration_tests"

clang++ -std=c++11 -Wall -Wextra -Werror -fsanitize=address,undefined "$root/firmware/tests/notification_queue_test.cpp" -o "$build_root/notification_queue_test"
"$build_root/notification_queue_test"

clang++ -std=c++11 -Wall -Wextra -Werror -ffast-math -fsanitize=address,undefined "$root/firmware/tests/lifetime_tests.cpp" -o "$build_root/lifetime_tests"
"$build_root/lifetime_tests"
