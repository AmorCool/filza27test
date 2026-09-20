# Filza Airlift (uk.nouvborne.filzaal) — jailed, sideloadable Filza whose only
# way outside the sandbox is the on-device AirTraffic transport (rust-core).
# No MHA, no MCM, no kernel code.
#
# arm64 only: the Airlift Rust staticlib is built solely for aarch64-ios and
# the Filza release base is a thin arm64 binary.
TARGET := iphone:clang:17.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FilzaApplySandboxExt

FilzaApplySandboxExt_FILES = Tweak.m \
	airlift/AirliftBridge.m \
	airlift/SetupViewController.m \
	airlift/AirliftBrowseViewController.m \
	airlift/AirliftIndex.m

# --- Airlift Rust core ---
AIRLIFT_LIB_DIR = $(PWD)/rust-core/target/aarch64-apple-ios/release

# --- Flags ---
FilzaApplySandboxExt_CFLAGS = \
    -I$(PWD)/rust-core/include -I$(PWD)/airlift \
    -fobjc-arc \
    -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable \
    -Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers \
    -Wno-deprecated-declarations -Wno-nonportable-include-path -Wno-format
FilzaApplySandboxExt_CFLAGS += -Wno-arc-performSelector-leaks

FilzaApplySandboxExt_CCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_OBJCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_OBJCCFLAGS = $(FilzaApplySandboxExt_CFLAGS)

FilzaApplySandboxExt_FRAMEWORKS = UIKit Foundation CoreFoundation Security
FilzaApplySandboxExt_LIBRARIES = z

# Rust airlift_ffi staticlib plus libc++. force_load ensures every Rust object
# (RPPairing host, loopback tunnel stack, AFC, streaming zip) is linked in.
FilzaApplySandboxExt_LDFLAGS = -Xlinker -force_load -Xlinker $(AIRLIFT_LIB_DIR)/libairlift_ffi.a -lc++

FilzaApplySandboxExt_INSTALL_TARGET_PROCESSES = Filza

# Force the Rust core to be built whenever `make` is invoked in this project,
# before the tweak sources are compiled. (`before-all` is a documented
# Theos project-level stage hook.)
before-all:: __airlift_rust_build
.PHONY: __airlift_rust_build
__airlift_rust_build:
	@echo "[airlift] building rust-core (aarch64-apple-ios release)…"
	bash scripts/build_rust_core.sh

include $(THEOS_MAKE_PATH)/tweak.mk