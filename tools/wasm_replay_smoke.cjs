#!/usr/bin/env node
// Smoke-tests the STATIC WASM replay viewer bundle — the artifact the
// observatory actually serves — by loading a fixture replay and stepping
// frames inside the wasm32 runtime, exactly as index.html does.
//
// Why this exists: the native test suite runs 64-bit, where Nim `int` is
// 64 bits and multi-GB allocations succeed. The shipped viewer is
// --cpu:wasm32 — `int` is 32 bits (overflow checks trap on arithmetic that
// is silently fine natively) and the address space ends at 2 GB. Both
// classes of bug reached prod invisible to CI and killed every hosted
// replay into a permanent "WARMING UP" (see PR #189: trenchEdgeNoise
// overflow, keyframe map-bake bloat). This script fails CI on the next one.
//
// It also drives playback across the WHOLE recording rather than a guessed
// number of frames: before r1 review B3 the gate advanced 300 frames at 1
// tick/frame on a 1085-tick replay, so the display player never reached the
// diverging tick and the gate could not fail. smac_replay_tick() /
// smac_replay_max_tick() make the target explicit, and `frames` is now a
// SAFETY CAP on how many frames that may take, not the measurement.
//
// Usage: node tools/wasm_replay_smoke.cjs <dist-dir> <replay-file> [frame-cap]

'use strict';
const fs = require('fs');
const path = require('path');

const distDir = path.resolve(process.argv[2] || 'replay-viewer/dist');
const replayPath = process.argv[3];
const frameCap = parseInt(process.argv[4] || '4000', 10);
if (!replayPath) {
  console.error('usage: wasm_replay_smoke.cjs <dist-dir> <replay-file> [frame-cap]');
  process.exit(2);
}

// A hung load (e.g. an allocation loop) must fail loudly, not stall the job.
const watchdog = setTimeout(() => {
  console.error('FAIL: smoke did not finish within 120s');
  process.exit(1);
}, 120000);

// The bundle is injected below with `Module` as a function parameter — a
// plain require() cannot configure it: the emitted `var Module` declaration
// hoists over any global we set, so locateFile/onRuntimeInitialized would be
// silently ignored and the .data preload resolves against the cwd.
const Module = {
  locateFile: (p) => path.join(distDir, p),
  onRuntimeInitialized: run,
  onAbort: (what) => {
    // Allocation failure aborts (-s ABORTING_MALLOC=1) but leaves linear
    // memory intact: the stage buffer still says what exhausted it.
    const stage = readStageNote();
    console.error('FAIL: wasm runtime aborted: ' + what +
      (stage ? '\nruntime was: ' + stage : ''));
    process.exit(1);
  },
};

function readStageNote() {
  try {
    const length = Module._smac_stage_len ? Module._smac_stage_len() : 0;
    if (!length) return '';
    const pointer = Module._smac_stage_ptr();
    return Buffer.from(Module.HEAPU8.subarray(pointer, pointer + length)).toString('utf8');
  } catch (ignored) {
    return '';
  }
}

function readRuntimeError() {
  const length = Module._smac_error_len();
  if (length) {
    const pointer = Module._smac_error_ptr();
    return Buffer.from(Module.HEAPU8.subarray(pointer, pointer + length)).toString('utf8');
  }
  const stage = readStageNote();
  return stage
    ? '(no error text; runtime was: ' + stage + ')'
    : '(runtime reported no error text)';
}

function run() {
  const bytes = fs.readFileSync(replayPath);
  const pointer = Module._malloc(bytes.length);
  Module.HEAPU8.set(bytes, pointer);
  const loaded = Module._smac_load_replay(pointer, bytes.length);
  Module._free(pointer);
  if (loaded !== 1) {
    console.error('FAIL: smac_load_replay rejected ' + path.basename(replayPath) +
      '\n' + readRuntimeError());
    process.exit(1);
  }
  if (Module._smac_packet_len() <= 0) {
    console.error('FAIL: first frame produced an empty packet');
    process.exit(1);
  }
  if (Module._smac_mismatch_tick() !== -1) {
    console.error('FAIL: replay hash mismatch at tick ' + Module._smac_mismatch_tick() +
      ' — the wasm sim diverged from the recording');
    process.exit(1);
  }
  // Drive playback to the LAST recorded tick. The hash chain is only checked
  // for the ticks something actually steps through, so a gate that stops early
  // cannot see a divergence past where it stopped -- and the precompute walk,
  // which does cross every tick, now publishes its verdict through the same
  // accessor (replays.replayMismatchTick).
  const maxTick = Module._smac_replay_max_tick();
  if (maxTick <= 0) {
    console.error('FAIL: replay reports no recorded ticks (max tick ' + maxTick + ')');
    process.exit(1);
  }
  let packetBytes = 0;
  let frames = 0;
  while (Module._smac_replay_tick() < maxTick && frames < frameCap) {
    if (Module._smac_frame() !== 1) {
      console.error('FAIL: smac_frame died at frame ' + frames + '\n' + readRuntimeError());
      process.exit(1);
    }
    frames += 1;
    packetBytes += Module._smac_packet_len();
    if (Module._smac_mismatch_tick() !== -1) {
      console.error('FAIL: replay hash mismatch at tick ' + Module._smac_mismatch_tick() +
        ' (frame ' + frames + ', playback tick ' + Module._smac_replay_tick() +
        ') -- the wasm sim diverged from the recording');
      process.exit(1);
    }
  }
  const reached = Module._smac_replay_tick();
  if (reached < maxTick) {
    console.error('FAIL: playback stalled at tick ' + reached + ' of ' + maxTick +
      ' after ' + frames + ' frames (cap ' + frameCap + '); the hash chain past ' +
      'that tick was never checked');
    process.exit(1);
  }
  if (Module._smac_mismatch_tick() !== -1) {
    console.error('FAIL: replay hash mismatch at tick ' + Module._smac_mismatch_tick() +
      ' after ' + frames + ' frames');
    process.exit(1);
  }
  clearTimeout(watchdog);
  console.log('ok: loaded ' + path.basename(replayPath) + ', played every tick to ' +
    maxTick + ' in ' + frames + ' frames, hash chain clean (' + packetBytes +
    ' packet bytes, heap ' +
    Math.round(Module.HEAPU8.length / 1024 / 1024) + ' MB)');
  process.exit(0);
}

const bundlePath = path.join(distDir, 'smac_replay.js');
new Function('Module', 'require', '__filename', '__dirname',
  fs.readFileSync(bundlePath, 'utf8'))(Module, require, bundlePath, distDir);
