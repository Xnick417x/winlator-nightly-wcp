#!/bin/bash -e

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator wget patch"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"

# VARIANT can be: a6xx-a7xx, a8xx
variant="${VARIANT:-a6xx-a7xx}"

# ALWAYS pull upstream Mesa main for true Nightlys
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"
mesabranch="main"
srcfolder="mesa-nightly-$variant"

run_all(){
	echo -e "${green}====== Begin building TU ${variant} V${BUILD_VERSION}! ======${nocolor}"
	check_deps
	prepare_workdir
	apply_patches
	build_lib_for_android
}

check_deps(){
	echo "Checking system for required Dependencies ..."
	for deps_chk in $deps; do
		if command -v "$deps_chk" >/dev/null 2>&1 ; then
			echo -e "$green - $deps_chk found $nocolor"
		else
			echo -e "$red - $deps_chk not found, can't continue. $nocolor"
			deps_missing=1
		fi
	done

	if [ "$deps_missing" == "1" ]; then
		echo "Please install missing dependencies" && exit 1
	fi

	echo "Installing python Mako dependency..."
	pip install mako &> /dev/null || true
}

prepare_workdir(){
	echo "Preparing work directory..."
	mkdir -p "$workdir" && cd "$workdir"

	if [ ! -d "$ndkver" ]; then
		echo "Downloading android-ndk from google server..."
		curl -sL https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
		echo "Extracting android-ndk..."
		unzip -q "$ndkver"-linux.zip &> /dev/null
	fi

	echo "Downloading upstream Mesa source (main)..."
	if [ ! -d "$srcfolder" ]; then
		git clone "$mesasrc" --depth 200 -b "$mesabranch" "$srcfolder"
	fi
	
	cd "$srcfolder"
	# Ensure SPIRV subprojects (Steven's stability fix)
	mkdir -p subprojects
	cd subprojects
	[ ! -d "spirv-tools" ] && git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools || true
	[ ! -d "spirv-headers" ] && git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers || true
	cd ..
}

apply_patches(){
	cd "$workdir/$srcfolder"
	git config --global user.email "builder@localhost"
	git config --global user.name "Builder"

	# 1. Apply Variant-Specific Community Logic
	if [[ "$variant" == *"a8xx"* ]]; then
		echo "Applying A8xx Master logic (Foundation + DiskDVD Upscaler)..."
		# Apply A8xx support base (Includes WB fixes)
		git apply --3way --whitespace=nowarn "../../patch/a8xx_base.patch" || true
		# Apply DiskDVD Upscaler extension
		git apply --3way --whitespace=nowarn "../../patch/diskdvd_upscaler.patch" || true
	else
		echo "Applying A6xx-A7xx Clean foundation..."
		git apply --3way --whitespace=nowarn "../../patch/a6xx_clean.patch" || true
	fi

	# 2. Apply 16g Scissor Clamp fix (Preserved as requested)
	echo "Applying 16g scissor clamp fix..."
	sed -i 's/#define MAX_VIEWPORT_SIZE (1 << 14)/#define MAX_VIEWPORT_SIZE 16384/g' src/freedreno/vulkan/tu_common.h || true

	# 3. Android compatibility hacks
	echo "Applying android compatibility hacks..."
	sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
	sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
	sed -i 's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' src/vulkan/runtime/vk_android.c || true

	# 4. Apply manual extra patch if provided
	if [ -n "$EXTRA_PATCH" ] && [ -f "../../$EXTRA_PATCH" ]; then
		echo "Applying extra patch: $EXTRA_PATCH"
		git apply --3way "../../$EXTRA_PATCH" || true
	fi
}

build_lib_for_android(){
	cd "$workdir/$srcfolder"
	echo "==== Compiling Mesa Nightly ===="

	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"
	export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"
	export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"

	GITHASH=$(git rev-parse --short HEAD)
	MESA_VERSION=$(cat VERSION 2>/dev/null | sed 's/-devel.*//' | tr -d '[:space:]' || echo "unknown")

	cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

	meson setup build-android-aarch64 \
		--cross-file "android-aarch64.txt" \
		--native-file "native.txt" \
		--prefix /tmp/turnip-$variant \
		-Dbuildtype=release \
		-Db_lto=false \
		-Dstrip=true \
		-Dplatforms=android \
		-Dvideo-codecs= \
		-Dplatform-sdk-version=36 \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dvulkan-beta=true \
		-Dfreedreno-kmds=kgsl \
		-Degl=disabled \
		-Dglx=disabled \
		-Dzstd=disabled \
		-Dwerror=false \
		-Dandroid-libbacktrace=disabled \
		--force-fallback-for=spirv-tools,spirv-headers \
		--reconfigure

	echo "Compiling build files..."
	ninja -C build-android-aarch64 install

	if ! [ -f /tmp/turnip-$variant/lib/libvulkan_freedreno.so ]; then
		echo -e "${red}Build failed!${nocolor}" && exit 1
	fi

	echo "Making the archive..."
	cd /tmp/turnip-$variant/lib

	NAME="Mesa Turnip ${MESA_VERSION}-${GITHASH}"
	if [[ "$variant" == *"a8xx"* ]]; then
		DESC="A8xx Nightly: Upstream Mesa + DiskDVD Master Tuning + FSR Extension."
	else
		DESC="A6xx/A7xx Nightly: Upstream Mesa + Whitebelyash Clean-26 fixes."
	fi

	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "$NAME",
  "description": "$DESC",
  "author": "Xnick417x",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
	zip -q "/tmp/mesa-turnip-$variant-V${BUILD_VERSION}.zip" libvulkan_freedreno.so meta.json
	cd - > /dev/null

	if ! [ -f "/tmp/mesa-turnip-$variant-V${BUILD_VERSION}.zip" ]; then
		echo -e "${red}Failed to pack the archive!${nocolor}"
	else
		cp "/tmp/mesa-turnip-$variant-V${BUILD_VERSION}.zip" "$workdir/"
		echo -e "${green}Build completed successfully!${nocolor}"
	fi
}

run_all
