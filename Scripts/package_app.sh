#!/usr/bin/env bash
set -euo pipefail

################################################################################
# This script builds the Display Anchor app, creates a .app bundle,
# and optionally installs it to /Applications. No fancy build system is used,
# just plain Swift Package Manager and shell commands.
################################################################################

# =============================================================================
# Configuration
# =============================================================================

APP_NAME="Display Anchor"
EXECUTABLE_NAME="DisplayAnchor"
BUNDLE_ID="com.jeff.DisplayAnchor"
# Keep it universal, so that the script can be used by anyone without modification
#DEFAULT_RELEASE_CODESIGN_IDENTITY="Developer ID Application: <YOUR_IDENTITY>"
DEFAULT_RELEASE_CODESIGN_IDENTITY="Developer ID Application: Joerg Hochwald (B2HP76Y3D4)"

# Configurable via environment variables
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
INSTALL_AFTER_BUILD="${INSTALL_AFTER_BUILD:-1}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-1}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
UNIVERSAL_BINARY="${UNIVERSAL_BINARY:-0}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

# Derived paths
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ICONSET_DIR="$ROOT_DIR/Resources/AppIcon.iconset"
APP_ICON_BASENAME="DisplayAnchor"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
INSTALLED_APP_DIR="$INSTALL_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# =============================================================================
# Logging & Utilities
# =============================================================================

log() {
	echo "[$(date '+%H:%M:%S')] $*"
}

log_verbose() {
	if [[ "$VERBOSE" == "1" ]]; then
		log "[VERBOSE] $*"
	fi
}

log_error() {
	echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
}

run_cmd() {
	if [[ "$DRY_RUN" == "1" ]]; then
		log "[DRY-RUN] $*"
	else
		log_verbose "Running: $*"
		"$@"
	fi
}

# =============================================================================
# Help & Usage
# =============================================================================

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Build and package the $APP_NAME application.

Options:
    -h, --help              Show this help message
    -c, --configuration     Build configuration (debug|release, default: release)
    -v, --version           App version string (default: 1.0)
    -b, --build-number      Build number (default: 1)
    --universal             Build universal binary (arm64 + x86_64)
    --no-install            Skip installation after build
    --no-launch             Skip launching after install
    --dry-run               Show what would be done without executing
    --verbose               Enable verbose output

Environment Variables:
    CONFIGURATION           Build configuration (default: release)
    VERSION                 App version string (default: 1.0)
    BUILD_NUMBER            Build number (default: 1)
    CODESIGN_IDENTITY       Code signing identity (optional)
    INSTALL_DIR             Installation directory (default: /Applications)
    INSTALL_AFTER_BUILD     Install after build: 0 or 1 (default: 1)
    LAUNCH_AFTER_INSTALL    Launch after install: 0 or 1 (default: 1)
    UNIVERSAL_BINARY        Build universal binary: 0 or 1 (default: 0)
    DRY_RUN                 Dry run mode: 0 or 1 (default: 0)
    VERBOSE                 Verbose output: 0 or 1 (default: 0)

Examples:
    $(basename "$0")                          # Build release, install, and launch
    $(basename "$0") -c debug --no-install    # Build debug only
    $(basename "$0") --universal -v 2.0       # Build universal binary v2.0
    CODESIGN_IDENTITY="My Cert" $(basename "$0")  # Build with custom signing

EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		-c | --configuration)
			CONFIGURATION="$2"
			shift 2
			;;
		-v | --version)
			VERSION="$2"
			shift 2
			;;
		-b | --build-number)
			BUILD_NUMBER="$2"
			shift 2
			;;
		--universal)
			UNIVERSAL_BINARY="1"
			shift
			;;
		--no-install)
			INSTALL_AFTER_BUILD="0"
			shift
			;;
		--no-launch)
			LAUNCH_AFTER_INSTALL="0"
			shift
			;;
		--dry-run)
			DRY_RUN="1"
			shift
			;;
		--verbose)
			VERBOSE="1"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			usage
			exit 1
			;;
		esac
	done

	# Validate configuration
	if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
		log_error "Invalid configuration: $CONFIGURATION (must be 'debug' or 'release')"
		exit 1
	fi

	# Update BUILD_DIR after parsing (in case configuration changed)
	BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
}

# =============================================================================
# Dependency & Environment Checks
# =============================================================================

check_dependencies() {
	log "Checking dependencies..."
	local missing=()

	for cmd in swift iconutil codesign ditto pgrep pkill; do
		if ! command -v "$cmd" &>/dev/null; then
			missing+=("$cmd")
		fi
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		log_error "Missing required commands: ${missing[*]}"
		log_error "Please ensure Xcode Command Line Tools are installed."
		exit 1
	fi

	log_verbose "All dependencies found"
}

check_resources() {
	log "Checking resources..."

	if [[ ! -d "$APP_ICONSET_DIR" ]]; then
		log_error "Missing app icon set at $APP_ICONSET_DIR"
		exit 1
	fi

	if [[ ! -f "$ROOT_DIR/Package.swift" ]]; then
		log_error "Missing Package.swift in $ROOT_DIR"
		exit 1
	fi

	log_verbose "All resources found"
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
	local exit_code=$?
	if [[ $exit_code -ne 0 ]]; then
		log_error "Build failed with exit code $exit_code"
		if [[ -d "$APP_DIR" ]]; then
			log "Cleaning up incomplete app bundle..."
			rm -rf "$APP_DIR"
		fi
	fi
	exit $exit_code
}

# =============================================================================
# Code Signing
# =============================================================================

resolve_codesign_identity() {
	local requested_identity="$1"

	# If a signing identity is explicitly requested, use it.
	if [[ -n "$requested_identity" ]]; then
		echo "$requested_identity"
		return
	fi

	# If no identity is requested, use the default for release builds.
	if [[ "$CONFIGURATION" == "release" ]]; then
		echo "$DEFAULT_RELEASE_CODESIGN_IDENTITY"
	fi
}

signing_identity_exists() {
	local identity="$1"

	[[ -n "$identity" ]] || return 1

	# Check if the signing identity exists in the keychain.
	security find-identity -v -p codesigning 2>/dev/null |
		awk -F'"' -v identity="$identity" '$2 == identity { found = 1 } END { exit(found ? 0 : 1) }'
}

sign_app() {
	local resolved_identity
	resolved_identity="$(resolve_codesign_identity "$CODESIGN_IDENTITY")"

	if [[ -z "$resolved_identity" ]]; then
		log "No signing identity configured for CONFIGURATION=$CONFIGURATION"
		log "Set CODESIGN_IDENTITY to sign this build."
		return
	fi

	if ! signing_identity_exists "$resolved_identity"; then
		log "Requested signing identity not found: $resolved_identity"
		log "Set CODESIGN_IDENTITY to a valid local certificate to sign this build."
		log "Continuing without bundle codesign so the project stays buildable on other machines."
		return
	fi

	log "Signing app bundle..."
	run_cmd codesign --force \
		--timestamp \
		--options runtime \
		--sign "$resolved_identity" \
		--identifier "$BUNDLE_ID" \
		"$APP_DIR"
	log "Signed $APP_DIR with identity: $resolved_identity"
}

# =============================================================================
# App Management
# =============================================================================

quit_running_app() {
	if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
		return
	fi

	log "Stopping running $APP_NAME..."
	pkill -x "$EXECUTABLE_NAME" || true

	# Wait for the app to quit, with a timeout of 5 seconds.
	local attempts=20
	for ((i = 1; i <= attempts; i++)); do
		if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
			log_verbose "App stopped after $i attempts"
			return
		fi
		sleep 0.25
	done

	log_error "Timed out waiting for $APP_NAME to quit."
	return 1
}

install_app() {
	if [[ "$INSTALL_AFTER_BUILD" != "1" ]]; then
		log "Skipping installation (INSTALL_AFTER_BUILD=0)"
		return
	fi

	quit_running_app

	log "Installing to $INSTALLED_APP_DIR..."
	run_cmd mkdir -p "$INSTALL_DIR"
	run_cmd /usr/bin/ditto "$APP_DIR" "$INSTALLED_APP_DIR"
	log "Installed $INSTALLED_APP_DIR"

	if [[ "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
		log "Launching $APP_NAME..."
		run_cmd /usr/bin/open "$INSTALLED_APP_DIR"
		log "Launched $INSTALLED_APP_DIR"
	else
		log "Skipping launch (LAUNCH_AFTER_INSTALL=0)"
	fi
}

# =============================================================================
# Build Process
# =============================================================================

build_swift_package() {
	log "Building $APP_NAME ($CONFIGURATION)..."

	local build_args=(
		build
		-c "$CONFIGURATION"
		--package-path "$ROOT_DIR"
	)

	if [[ "$UNIVERSAL_BINARY" == "1" ]]; then
		log "Building universal binary (arm64 + x86_64)..."
		build_args+=(--arch arm64 --arch x86_64)
	fi

	if ! run_cmd swift "${build_args[@]}"; then
		log_error "Swift build failed"
		exit 1
	fi

	log "Build completed successfully"
}

create_app_bundle() {
	log "Creating app bundle..."

	# Clean and create directory structure
	run_cmd rm -rf "$APP_DIR"
	run_cmd mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

	# Copy executable
	local executable_src="$BUILD_DIR/$EXECUTABLE_NAME"
	if [[ "$UNIVERSAL_BINARY" == "1" ]]; then
		# Universal binaries may be in a different location
		executable_src="$ROOT_DIR/.build/apple/Products/$CONFIGURATION/$EXECUTABLE_NAME"
		if [[ ! -f "$executable_src" ]]; then
			executable_src="$BUILD_DIR/$EXECUTABLE_NAME"
		fi
	fi

	if [[ ! -f "$executable_src" ]]; then
		log_error "Executable not found at $executable_src"
		exit 1
	fi

	run_cmd cp "$executable_src" "$MACOS_DIR/$EXECUTABLE_NAME"
	run_cmd chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

	log_verbose "Copied executable from $executable_src"
}

create_app_icon() {
	log "Creating app icon..."
	run_cmd iconutil -c icns "$APP_ICONSET_DIR" -o "$RESOURCES_DIR/$APP_ICON_BASENAME.icns"
}

create_info_plist() {
	log "Creating Info.plist (version $VERSION, build $BUILD_NUMBER)..."

	if [[ "$DRY_RUN" == "1" ]]; then
		log "[DRY-RUN] Would create $CONTENTS_DIR/Info.plist"
		return
	fi

	cat >"$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>$APP_ICON_BASENAME</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © $(date +%Y) Jeffrey Schumann. All rights reserved.</string>
</dict>
</plist>
PLIST
}

print_summary() {
	log "=============================================="
	log "Build Summary"
	log "=============================================="
	log "  App:            $APP_NAME"
	log "  Version:        $VERSION ($BUILD_NUMBER)"
	log "  Configuration:  $CONFIGURATION"
	log "  Universal:      $([[ "$UNIVERSAL_BINARY" == "1" ]] && echo "Yes" || echo "No")"
	log "  Output:         $APP_DIR"
	if [[ "$INSTALL_AFTER_BUILD" == "1" ]]; then
		log "  Installed to:   $INSTALLED_APP_DIR"
	fi
	log "=============================================="
}

# =============================================================================
# Main
# =============================================================================

main() {
	# Parse command line arguments
	parse_args "$@"

	# Set up cleanup trap
	trap cleanup EXIT

	log "=============================================="
	log "Building $APP_NAME v$VERSION"
	log "=============================================="

	if [[ "$DRY_RUN" == "1" ]]; then
		log "Running in DRY-RUN mode - no changes will be made"
	fi

	# Pre-flight checks
	check_dependencies
	check_resources

	# Build process
	build_swift_package
	create_app_bundle
	create_app_icon
	create_info_plist

	# Sign the app
	sign_app

	log "Created $APP_DIR"

	# Install if requested
	install_app

	# Print summary
	print_summary

	log "Done!"
}

main "$@"
