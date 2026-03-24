#!/bin/bash

# 目录配置
BASE_DIR="$(pwd)"
SRC_DIR="${BASE_DIR}/ffmpeg-src"
BUILD_DIR="${BASE_DIR}/ffmpeg-build"
XCFRAMEWORK_DIR="${BASE_DIR}/FFmpeg.xcframework"

FFMPEG_VERSION="6.1.1"
FFMPEG_TARBALL="ffmpeg-${FFMPEG_VERSION}.tar.bz2"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_TARBALL}"

# 下载并解压 FFmpeg
if [ ! -d "${SRC_DIR}" ]; then
    echo "Downloading FFmpeg ${FFMPEG_VERSION}..."
    curl -O "${FFMPEG_URL}"
    mkdir -p "${SRC_DIR}"
    tar jxf "${FFMPEG_TARBALL}" -C "${SRC_DIR}" --strip-components=1
    rm "${FFMPEG_TARBALL}"
fi

# 极简配置选项（仅支持 MP4, H.264 解码, AAC 解码, Metal/VideoToolbox 硬件加速）
CONFIGURE_FLAGS="
    --prefix=PREFIX_PLACEHOLDER
    --enable-cross-compile
    --target-os=darwin
    --arch=ARCH_PLACEHOLDER
    --cc=CC_PLACEHOLDER
    --as=CC_PLACEHOLDER
    --sysroot=SYSROOT_PLACEHOLDER
    --extra-cflags=-arch ARCH_PLACEHOLDER -mios-version-min=12.0
    --extra-ldflags=-arch ARCH_PLACEHOLDER -mios-version-min=12.0
    --disable-programs
    --disable-doc
    --disable-debug
    --disable-everything
    --enable-avformat
    --enable-avcodec
    --enable-swscale
    --enable-swresample
    --enable-avutil
    --enable-decoder=h264
    --enable-decoder=aac
    --enable-demuxer=mov
    --enable-protocol=file
    --enable-videotoolbox
    --enable-audiotoolbox
    --disable-iconv
    --disable-network
    --disable-zlib
    --disable-bzlib
    --disable-lzma
"

build_arch() {
    ARCH=$1
    SDK_PLATFORM=$2
    SDK_MIN_VERSION=$3
    
    echo "Building FFmpeg for ${ARCH} (${SDK_PLATFORM})..."
    
    XCRUN_SDK=$(xcrun --sdk ${SDK_PLATFORM} --show-sdk-path)
    # 修改这里的 CC 和 AS 配置方式，避免 --cc 参数识别错误
    CC="xcrun -sdk ${SDK_PLATFORM} clang"
    
    ARCH_BUILD_DIR="${BUILD_DIR}/${SDK_PLATFORM}_${ARCH}"
    mkdir -p "${ARCH_BUILD_DIR}"
    
    cd "${SRC_DIR}"
    
    # 构建 configure 参数，注意不要用占位符替换，直接拼接字符串以避免空格引起的转义问题
    EXTRA_CFLAGS="-arch ${ARCH} -mios-version-min=12.0"
    EXTRA_LDFLAGS="-arch ${ARCH} -mios-version-min=12.0"
    
    if [ "${SDK_PLATFORM}" == "iphonesimulator" ]; then
        EXTRA_CFLAGS="-arch ${ARCH} -mios-simulator-version-min=12.0"
        EXTRA_LDFLAGS="-arch ${ARCH} -mios-simulator-version-min=12.0"
    fi
    
    ./configure \
        --prefix="${ARCH_BUILD_DIR}" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch="${ARCH}" \
        --cc="${CC}" \
        --sysroot="${XCRUN_SDK}" \
        --extra-cflags="${EXTRA_CFLAGS}" \
        --extra-ldflags="${EXTRA_LDFLAGS}" \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-everything \
        --enable-avformat \
        --enable-avcodec \
        --enable-swscale \
        --enable-swresample \
        --enable-avutil \
        --enable-decoder=h264 \
        --enable-decoder=aac \
        --enable-demuxer=mov \
        --enable-protocol=file \
        --enable-videotoolbox \
        --enable-audiotoolbox \
        --disable-iconv \
        --disable-network \
        --disable-zlib \
        --disable-bzlib \
        --disable-lzma \
        --disable-x86asm
    
    make clean
    make -j8
    make install
    cd "${BASE_DIR}"
}

# 编译真机架构 (arm64)
build_arch arm64 iphoneos

# 编译模拟器架构 (arm64 和 x86_64)
build_arch arm64 iphonesimulator
build_arch x86_64 iphonesimulator

# 将模拟器的两个架构合并为一个胖库 (Fat Library)
SIM_FAT_DIR="${BUILD_DIR}/iphonesimulator_fat"
mkdir -p "${SIM_FAT_DIR}/lib"
mkdir -p "${SIM_FAT_DIR}/include"
cp -r "${BUILD_DIR}/iphonesimulator_arm64/include/"* "${SIM_FAT_DIR}/include/"

for lib in libavcodec libavformat libavutil libswresample libswscale; do
    lipo -create -output "${SIM_FAT_DIR}/lib/${lib}.a" \
        "${BUILD_DIR}/iphonesimulator_arm64/lib/${lib}.a" \
        "${BUILD_DIR}/iphonesimulator_x86_64/lib/${lib}.a"
done

# 生成 XCFramework
echo "Creating XCFramework..."
rm -rf "${XCFRAMEWORK_DIR}"
mkdir -p "${XCFRAMEWORK_DIR}"

for lib in libavcodec libavformat libavutil libswresample libswscale; do
    # 修复：只提取当前库的头文件以避免 Xcode 报错 multiple commands produce
    mkdir -p "${BUILD_DIR}/iphoneos_arm64/headers_${lib}/${lib}"
    cp -r "${BUILD_DIR}/iphoneos_arm64/include/${lib}/"* "${BUILD_DIR}/iphoneos_arm64/headers_${lib}/${lib}/"
    
    mkdir -p "${SIM_FAT_DIR}/headers_${lib}/${lib}"
    cp -r "${SIM_FAT_DIR}/include/${lib}/"* "${SIM_FAT_DIR}/headers_${lib}/${lib}/"
    
    # 针对 libavutil 这个特殊的库，可能有一些散落的头文件需要处理，简单起见我们按库名拷贝
    xcodebuild -create-xcframework \
        -library "${BUILD_DIR}/iphoneos_arm64/lib/${lib}.a" -headers "${BUILD_DIR}/iphoneos_arm64/headers_${lib}" \
        -library "${SIM_FAT_DIR}/lib/${lib}.a" -headers "${SIM_FAT_DIR}/headers_${lib}" \
        -output "${XCFRAMEWORK_DIR}/${lib}.xcframework"
done

echo "FFmpeg XCFramework created at ${XCFRAMEWORK_DIR}"
