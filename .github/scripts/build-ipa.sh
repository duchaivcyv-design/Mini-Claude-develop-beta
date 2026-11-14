#!/usr/bin/env bash
# Build GestaltX with Xcode and package an App Group-aware ad-hoc IPA.
# Usage: .github/scripts/build-ipa.sh [output-dir]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mkdir -p "${1:-$root/build/ipa}" && cd "${1:-$root/build/ipa}" && pwd)"
cd "$root"

for required in GestaltX.xcodeproj/project.pbxproj GestaltX/GestaltX.entitlements; do
  [[ -e "$root/$required" ]] || {
    echo "Error: required GestaltX project file is missing: $required" >&2
    exit 1
  }
done

version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);/\1/p' GestaltX.xcodeproj/project.pbxproj | sort -u)"
if [[ -z "$version" || "$(wc -l <<< "$version" | tr -d ' ')" -ne 1 ]]; then
  echo "Error: expected exactly one MARKETING_VERSION, found: ${version:-none}" >&2
  exit 1
fi
echo "==> Building GestaltX $version"

if [[ -n "${BUILD_DATE:-}" ]]; then
  printf '%s' "$BUILD_DATE" > GestaltX/BuildDate.txt
fi
if [[ -f scripts/generate_localization.py ]]; then
  python3 scripts/generate_localization.py
fi

# Fail early with a useful message if the native dependency was not restored.
if grep -q 'GXDeviceConsole' GestaltX.xcodeproj/project.pbxproj; then
  framework="$root/Native/DeviceConsole/build/GXDeviceConsole.xcframework"
  if [[ ! -d "$framework" ]]; then
    echo "Error: project references GXDeviceConsole but the XCFramework is missing: $framework" >&2
    exit 1
  fi
fi

xcodebuild \
  -project GestaltX.xcodeproj \
  -target GestaltX \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$root/build/DerivedData" \
  SYMROOT="$root/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' \
  build

app_product="$root/build/Release-iphoneos/GestaltX.app"
if [[ ! -d "$app_product" ]]; then
  echo "Error: Xcode did not produce $app_product" >&2
  find "$root/build" -maxdepth 5 -name '*.app' -print >&2 || true
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload" "$out"
cp -R "$app_product" "$stage/Payload/"
app="$stage/Payload/GestaltX.app"
appex="$app/PlugIns/GestaltXShare.appex"

# Sign nested code from the inside out, then the extension, then the app.
while IFS= read -r -d '' item; do
  codesign -f -s - "$item"
done < <(find "$app" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)

bundles=()
if [[ -d "$appex" ]]; then
  extension_entitlements="$root/ShareExtension/GestaltXShare.entitlements"
  [[ -f "$extension_entitlements" ]] || {
    echo "Error: share extension entitlements are missing: $extension_entitlements" >&2
    exit 1
  }
  codesign -f -s - --entitlements "$extension_entitlements" "$appex"
  bundles+=("$appex")
fi
codesign -f -s - --entitlements "$root/GestaltX/GestaltX.entitlements" "$app"
bundles+=("$app")

# Verify that signatures are ad-hoc and App Group entitlements survived.
python3 - "${bundles[@]}" <<'PYVERIFY'
import plistlib, subprocess, sys
common = None
for bundle in sys.argv[1:]:
    subprocess.run(["codesign", "--verify", "--strict", bundle], check=True)
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", bundle],
        capture_output=True, check=True,
    )
    entitlements = plistlib.loads(result.stdout)
    groups = entitlements.get("com.apple.security.application-groups", [])
    if not isinstance(groups, list) or not groups or not all(isinstance(x, str) and x for x in groups):
        raise SystemExit(f"Missing App Group entitlements in {bundle}")
    if entitlements.get("com.apple.developer.team-identifier"):
        raise SystemExit(f"Unexpected developer Team ID in ad-hoc bundle: {bundle}")
    metadata = subprocess.run(["codesign", "-dvv", bundle], capture_output=True, text=True, check=True).stderr
    if "Signature=adhoc" not in metadata or "TeamIdentifier=not set" not in metadata:
        raise SystemExit(f"Expected ad-hoc signature in {bundle}")
    common = set(groups) if common is None else common.intersection(groups)
if not common:
    raise SystemExit("The app and extension do not share a common App Group")
print("Verified ad-hoc signatures and common App Group entitlements.")
PYVERIFY

ipa="$out/GestaltX_${version}.ipa"
(cd "$stage" && COPYFILE_DISABLE=1 zip -qry -X "$ipa" Payload)
echo "==> Created IPA: $ipa"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$version"
    echo "ipa=$ipa"
  } >> "$GITHUB_OUTPUT"
fi
