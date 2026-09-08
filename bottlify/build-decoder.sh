#!/usr/bin/env bash
# Copyright © 2026 Bottlify Project
# Licensed under the Mozilla Public License, version 2.0
# See https://mozilla.org/MPL/2.0/ for details
#
# Builds video-decoder.wasm: a curated FFmpeg compiled to WebAssembly, linked
# with decoder.c. Runs inside the image built from Dockerfile.
#
#   build-decoder.sh <ffmpeg_source_dir> <out_dir> <work_dir>
#
# The source tree is this repository. There is nothing to clone and no tag to
# pin: the checkout *is* the FFmpeg being built, and what a release fetches is
# tied to a commit of this branch. The build is out-of-tree so that the source
# can be mounted read-only and nothing lands back in the checkout.
#
# LICENCE POSITION, and it is not a detail: neither --enable-gpl nor
# --enable-nonfree is passed. What comes out is FFmpeg under LGPL-2.1-or-later,
# which ships alongside an MPL-2.0 product as a separately licensed component
# whose corresponding source is this repository at the commit that built it.
# Adding either flag relicenses the whole artifact; do not add them.
set -euo pipefail

SRC="${1:?usage: build-decoder.sh <ffmpeg_source_dir> <out_dir> <work_dir>}"
OUT="${2:?usage: build-decoder.sh <ffmpeg_source_dir> <out_dir> <work_dir>}"
WORK="${3:-/work}"

BUILD_DIR="${WORK}/ffmpeg-build"
INSTALL_DIR="${WORK}/ffmpeg-install"

mkdir -p "${OUT}" "${BUILD_DIR}" "${INSTALL_DIR}"

# Component names here are configure's names, which are not always the name the
# runtime reports, and an unrecognised one is ignored in silence rather than
# refused -- so a typo does not fail the build, it produces a decoder that
# cannot open a file. Every name below is a configure component
# (--list-demuxers / --list-decoders / --list-parsers); the MPEG program-stream
# demuxer is the clearest trap, `mpegps` here and "mpeg" at runtime. The lists
# are variables rather than literal flags only so that the check after configure
# can assert the same names against config.h.
#
# What the set covers: the containers and codecs a Windows game of the late
# nineties and early two-thousands shipped its cinematics in. AVI carrying
# MPEG-4 part 2 with MP3 is the case that must work; the rest is the same era's
# long tail, which costs kilobytes each and is far cheaper to carry now than to
# discover missing later.
DEMUXERS="avi,mov,asf,wav,ogg,flv,dv"
DEMUXERS="${DEMUXERS},mpegps,mpegvideo,mpegts"
DEMUXERS="${DEMUXERS},bink,smacker,vmd,flic,roq,idcin,fourxm,str"

DECODERS="mpeg4,msmpeg4v1,msmpeg4v2,msmpeg4v3,h263,h263i"
DECODERS="${DECODERS},mpeg1video,mpeg2video,wmv1,wmv2,wmv3,vc1,flv"
DECODERS="${DECODERS},cinepak,indeo2,indeo3,indeo4,indeo5,msvideo1,msrle"
DECODERS="${DECODERS},rawvideo,mjpeg,mjpegb,svq1,svq3,rpza,qtrle,smc,qdraw"
DECODERS="${DECODERS},qpeg,tscc,truemotion1,truemotion2,dvvideo,theora"
DECODERS="${DECODERS},vp3,vp5,vp6,vp6a,vp6f"
DECODERS="${DECODERS},bink,smacker,vmdvideo,flic,roq,idcin,interplay_video"
DECODERS="${DECODERS},mdec,fourxm"
DECODERS="${DECODERS},mp1,mp2,mp3,mp1float,mp2float,mp3float"
DECODERS="${DECODERS},wmav1,wmav2,vorbis,nellymoser,truespeech,qdm2"
DECODERS="${DECODERS},binkaudio_dct,binkaudio_rdft,smackaud,vmdaudio"
DECODERS="${DECODERS},roq_dpcm,interplay_dpcm,xan_dpcm"
DECODERS="${DECODERS},pcm_u8,pcm_s8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le"
DECODERS="${DECODERS},pcm_f32le,pcm_alaw,pcm_mulaw"
DECODERS="${DECODERS},adpcm_ms,adpcm_ima_wav,adpcm_ima_ws,adpcm_ima_qt"
DECODERS="${DECODERS},adpcm_ea,adpcm_xa,adpcm_swf,adpcm_4xm,adpcm_g726"

PARSERS="mpeg4video,mpegvideo,mpegaudio,h263,vp3,vc1,vorbis"

BSFS="extract_extradata,mpeg4_unpack_bframes"

if [ ! -f "${INSTALL_DIR}/lib/libavcodec.a" ]; then
    cd "${BUILD_DIR}"
    emconfigure "${SRC}/configure" \
        --prefix="${INSTALL_DIR}" \
        --disable-everything \
        --enable-demuxer="${DEMUXERS}" \
        --enable-decoder="${DECODERS}" \
        --enable-parser="${PARSERS}" \
        --enable-bsf="${BSFS}" \
        --enable-avformat --enable-avcodec --enable-avutil \
        --enable-swscale --enable-swresample \
        --disable-programs --disable-doc --disable-autodetect \
        --disable-network --disable-debug \
        --disable-iconv --disable-zlib --disable-bzlib --disable-lzma --disable-sdl2 \
        --disable-x86asm --disable-inline-asm --disable-pthreads \
        --enable-cross-compile \
        --target-os=none \
        --arch=c \
        --cc=emcc \
        --cxx=em++ \
        --ar=emar \
        --ranlib=emranlib \
        --nm="${EMSDK}/upstream/bin/llvm-nm" \
        --extra-cflags="-O2"

    # The silence above is the whole reason for this: the generated headers are
    # the only place that say what configure actually accepted, so every
    # requested name is asserted against them and a name that stopped existing
    # fails the build here rather than at the first file a game tries to play.
    # Components live in config_components.h, not config.h -- reading only the
    # latter finds nothing and looks exactly like a build with no codecs in it.
    cat config.h config_components.h > "${WORK}/enabled.h"
    missing=""
    for group in "DEMUXER:${DEMUXERS}" "DECODER:${DECODERS}" \
                 "PARSER:${PARSERS}" "BSF:${BSFS}"; do
        kind="${group%%:*}"
        for name in $(printf '%s' "${group#*:}" | tr ',' ' '); do
            macro="CONFIG_$(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]')_${kind}"
            if ! grep -qE "^#define ${macro} 1$" "${WORK}/enabled.h"; then
                missing="${missing} ${kind}:${name}"
            fi
        done
    done
    if [ -n "${missing}" ]; then
        echo "configure did not enable:${missing}" >&2
        exit 1
    fi

    emmake make -j"$(nproc)" install-libs install-headers
fi

# --no-entry, because there is no main: without it the module imports one and
# the caller has to answer for something that is never called.
#
# Undefined symbols are tolerated for a related reason: a curated FFmpeg still
# references a handful of libc and host entry points -- time zones, file
# descriptors -- that this build's code paths never reach, and the JavaScript
# side answers any leftover import with a no-op rather than failing to
# instantiate.
emcc "${SRC}/bottlify/decoder.c" \
    -I"${INSTALL_DIR}/include" \
    -L"${INSTALL_DIR}/lib" \
    -lavformat -lavcodec -lswscale -lswresample -lavutil \
    -O2 \
    --no-entry \
    -sSTANDALONE_WASM=1 \
    -sALLOW_MEMORY_GROWTH=1 \
    -sINITIAL_MEMORY=33554432 \
    -sERROR_ON_UNDEFINED_SYMBOLS=0 \
    -sEXPORTED_FUNCTIONS='["_media_alloc","_media_free","_media_open","_media_info","_media_codec_name","_media_decode","_media_frame","_media_audio_pending","_media_audio_read","_media_close"]' \
    -o "${OUT}/video-decoder.wasm"

cd "${OUT}"
sha256sum video-decoder.wasm > SHA256SUMS
cat SHA256SUMS
