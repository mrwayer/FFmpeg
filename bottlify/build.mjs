/*
 * Copyright © 2026 Bottlify Project
 * Licensed under the Mozilla Public License, version 2.0
 * See https://mozilla.org/MPL/2.0/ for details
 */

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Builds video-decoder.wasm in a pinned container and records what produced it.
 *
 * This is the from-source path and it is the authoritative one: the workflow
 * runs exactly this and publishes what comes out as a release, and the
 * consuming project only ever fetches that release. A machine needs Docker and
 * nothing else -- no Emscripten, no FFmpeg toolchain.
 *
 * The source it builds is this repository, mounted read-only; everything
 * written lands under bottlify/out and bottlify/work, both untracked.
 */

const HERE = resolve(fileURLToPath(new URL('.', import.meta.url)));
const ROOT = resolve(HERE, '..');
const OUT = join(HERE, 'out');
/* An FFmpeg build tree and its object files, kept between runs so that editing
 * decoder.c costs a link rather than a full rebuild. */
const WORK = join(HERE, 'work');
const IMAGE = 'bottlify-video-decoder-builder:0.1';

/** @param {string} path @returns {string} */
function sha256Hex(path){
    return createHash('sha256').update(readFileSync(path)).digest('hex');
}

/** @param {string[]} args @param {{ capture?: boolean }} [options] */
function docker(args, options = {}){
    return spawnSync('docker', args, {
        stdio: options.capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
        encoding: 'utf8',
    });
}

function requireDocker(){
    if (docker(['version', '--format', '{{.Server.Version}}'], { capture: true }).status !== 0)
    {
        throw new Error('docker is required to build the video decoder and is not available.');
    }
}

function ensureImage(){
    if (spawnSync('docker', ['image', 'inspect', IMAGE], { stdio: 'ignore' }).status === 0)
    {
        return;
    }
    if (docker(['build', '-t', IMAGE, HERE]).status !== 0)
    {
        throw new Error('failed to build the video-decoder builder image');
    }
}

requireDocker();
ensureImage();
await mkdir(OUT, { recursive: true });
await mkdir(WORK, { recursive: true });

const run = docker([
    'run', '--rm',
    '-v', `${ROOT}:/src:ro`,
    '-v', `${OUT}:/out`,
    '-v', `${WORK}:/work`,
    IMAGE, '/src', '/out', '/work',
], { capture: true });
if (run.status !== 0)
{
    throw new Error('containerized video-decoder build failed');
}
process.stdout.write(run.stdout);

// The commit is what makes a published hash mean something: it names the exact
// tree whose corresponding source this artifact is.
const commit = spawnSync('git', ['-C', ROOT, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
const artifact = join(OUT, 'video-decoder.wasm');
await writeFile(join(OUT, 'video-decoder.manifest.json'), `${JSON.stringify({
    ffmpeg: {
        repo: 'https://github.com/mrwayer/FFmpeg',
        commit: commit.status === 0 ? commit.stdout.trim() : null,
        license: 'LGPL-2.1-or-later',
    },
    image: IMAGE,
    artifacts: { './video-decoder.wasm': `sha256:${sha256Hex(artifact)}` },
    builtAt: new Date().toISOString(),
}, null, 2)}\n`);

console.log('bottlify/out: video-decoder.wasm + SHA256SUMS + video-decoder.manifest.json');
