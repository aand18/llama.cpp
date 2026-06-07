# mtmd Video Support — Design & Port Notes

Personal fork's port of upstream PR [#21858](https://github.com/ggml-org/llama.cpp/pull/21858) ("mtmd seq-of-images"), an ffmpeg-backed `--video` flag in `llama-mtmd-cli`, and follow-on work that **removes the original `nt<=2` cap** by adding pair-chunking to the Qwen-VL encoder, an M-RoPE T-axis, and a per-frame pixel budget that matches `qwen-vl-utils.fetch_video()`. Targets Qwen3-VL (and Qwen2.5-VL) since the user already runs Qwen3.6-27B in production.

This document is the design/rationale companion to the code. **For agent-facing notes (build commands, test invocations, defaults), see `AGENTS.md`.** For the actual diff, see the commits on `feature/qwen36-video-support-isolated`.

## Goal

Add full-length video input to `llama-mtmd-cli` so the user can pass a clip of arbitrary length (mp4/mov/etc.) and ask the model to describe it. The user already has the Qwen3.6-27B MTP GGUF + mmproj locally; this is a CLI feature, not a server feature (server-side tracking is [issue #18389](https://github.com/ggml-org/llama.cpp/issues/18389)).

## Why this approach (over alternatives)

Three paths were considered for the original port:

1. **Port upstream PR #21858** (chosen). Maintainer ngxson authored it and it's tracked in his "hot" [issue #18389](https://github.com/ggml-org/llama.cpp/issues/18389). It matches the maintainer's stated direction: `nt` field on `mtmd_bitmap`, `clip_model_supports_seq_input()` gate, `add_seq_image()` dispatcher, ffmpeg via subprocess.
2. **[Cobdog/llama-video](https://github.com/Cobdog/llama-video)** third-party fork. Diverges from the maintainer's plan: introduces `MTMD_POS_TYPE_VIDEO` and packs 6 frames into one 6-channel super-frame. More invasive, harder to reconcile with mainline.
3. Hand-rolled. Out of scope; duplicates maintainer effort.

Chose #1 because (a) it tracks the maintainer's roadmap, (b) the diff is small once the foundation is in, (c) it composes cleanly with the existing `add_image` path.

For the follow-on work (encoder extension beyond `nt=2`):

- The "chunk in `add_seq_image`" alternative was rejected because the vision encoder's `build_inp_with_temporal_merge` graph *itself* could not handle `nt>2` — it had an unconditional `GGML_ASSERT(nt <= 2)`. The encoder has to learn to process arbitrary even `nt` before `add_seq_image` can chunk it.
- The chosen approach (pair-chunking inside the encoder graph, then per-pair chunks in `add_seq_image`) keeps the encoder change local to one function and matches the Qwen-VL `temporal_patch_size=2` invariant from the upstream design.

## What was ported vs. what was added locally

### Ported from upstream PR #21858 (cleanup commit `c5b682b`)

Five files applied cleanly to `local/integrated`:

- `tools/mtmd/clip-graph.h` — `clip_graph.nt = 1` field
- `tools/mtmd/clip-impl.h` — `clip_image_f32_batch.is_seq = true` field
- `tools/mtmd/models/models.h` — `clip_graph_qwen3vl` inherits `clip_graph_qwen2vl`; `build_inp_with_temporal_merge` decl
- `tools/mtmd/models/qwen2vl.cpp` — `build_inp_with_temporal_merge()` body (initially handled only `nt==1`, `nt==2`)
- `tools/mtmd/models/qwen3vl.cpp` — switches to `build_inp_with_temporal_merge()`

Six files had conflicts (20 hunks total) due to local divergence on HunyuanVL. Resolution strategy: preserve local HunyuanVL additions, apply patch intent for seq/nt fields.

### Two bugs fixed in the PR itself

These are **upstream PR bugs** that would block every seq bitmap. Without these fixes, the patch is dead code.

- **`mtmd.cpp:774` — missing dispatch.** The cleanup commit accidentally removed `if (bitmap->nt >= 2) return add_seq_image(bitmap);` from `add_media()`. Without it, every video bitmap silently degrades to single-image preprocessing. Restored.
- **`clip.cpp:847` — unconditional assert.** `clip_image_build_graph` starts with `GGML_ASSERT(imgs.entries.size() == 1 && "n_batch > 1 is not supported")`, but the patch sets `builder->nt = imgs.entries.size()` at the end — repurpose batch dim as temporal. The assert blocks batch>1 outright, so the new code path was unreachable. Fixed by skipping the assert when `clip_model_supports_seq_input()` is true (currently `PROJECTOR_TYPE_QWEN2VL/QWEN25VL/QWEN3VL`). The dispatcher in `clip_image_batch_encode` already short-circuits `batch>1` for non-seq models, so reaching the assert with batch>1 implies the model can handle it.

### Added locally (port + encoder extension + CLI budget)

- `mtmd_helper_bitmap_init_from_video(ctx, fname, fps, min_frames, max_frames, min_tokens, max_tokens, total_pixels)` in `mtmd-helper.{h,cpp}`. `ffprobe` for native dimensions, `ffmpeg` subprocess (`popen`) for raw RGB24 extraction at target fps, then `mtmd_bitmap_init_from_seq` constructs the bitmap. No FFmpeg linking — keeps the binary lean and respects the no-FFmpeg-CGO policy in this fork.
- `--video` / `--video-fps` / `--video-min-frames` / `--video-max-frames` / `--video-min-tokens` / `--video-max-tokens` / `--video-total-pixels` flags in `common/{arg.cpp,common.h}`.
- `mtmd-cli.cpp`: `load_video()` method, wired into both single-turn mode and chat-mode `/video <path>` command.
- **Encoder pair-chunking** (`qwen2vl.cpp::build_inp_with_temporal_merge`, mirrored in `qwen3vl.cpp`). Replaces the upstream `GGML_ASSERT(nt <= 2)` with a loop over `nt/2` pairs: each pair is `ggml_conv_2d(patch_embeddings_0, frame_2i) + ggml_conv_2d(patch_embeddings_1, frame_2i+1)`, then all pair outputs are `ggml_concat`'d along the H axis. `build()` recomputes `n_pos = n_patches_x * h_dim` from the actual tensor shape so subsequent reshapes work for any `nt`.
- **M-RoPE T-axis** (`mtmd.cpp::mtmd_image_tokens_get_decoder_pos`, with `image_tokens->nt` field). Still images keep `pos.t = 0`. For video, `pos.t` advances by one per pair, `pos.x` / `pos.y` are spatial within pair, `pos.z = 0`. This is true 3D M-RoPE for video frames.
- **Per-pair chunks in LLM integration** (`mtmd.cpp::add_seq_image`). The encoder returns a single concatenated embedding for all pairs, but `add_seq_image` splits it into one `mtmd_input_chunk` per pair (with `image_tokens->nt = 1` each). This is required because hybrid memory's `find_slot` needs unique positions per chunk; a multi-pair chunk can't share positions.
- **Per-frame pixel budget** (`mtmd-helper.cpp::compute_per_frame_max` + `mtmd_helper_smart_resize` C API). Matches the `qwen-vl-utils.fetch_video()` formula: `per_frame_max = min(VIDEO_MAX_TOKEN_NUM * factor², total_pixels * FRAME_FACTOR / nframes)`. When the per-frame budget is smaller than the source frame, the ffmpeg filter chain gets a `-vf scale=W:H` prepended.
- **CLI defaults** matching `qwen-vl-utils`: `--video-fps 2.0`, `--video-min-frames 4` (qwen-vl-utils `FPS_MIN_FRAMES`), `--video-max-frames 768` (qwen-vl-utils `FPS_MAX_FRAMES`).
- **Context size documentation**: `-c` must be sized to total image tokens. See [Context size for video](#context-size-for-video-kv-cache-requirement) below.
- `build-cuda.ps1`: explicit `CUDA_TOOLKIT_ROOT_DIR=v13.1` because MSVC BuildTools 2022 ships only 12.6 + 13.1 `BuildCustomizations`. Without the override, CMake finds v13.3 (newest on disk) but MSBuild invokes v13.1 nvcc, producing "CUDA compiler and CUDA toolkit headers are incompatible" on every `.cu`.

## ffmpeg extraction design

Constraints: no FFmpeg linking (binary size + no GPL/LGPL in the main binary), and Windows process must use a real shell pipe. Approach:

1. `ffprobe` to get native width/height and duration (fast, no decode).
2. **Compute per-frame pixel budget** (qwen-vl-utils formula — see [Per-frame pixel budget](#per-frame-pixel-budget)).
3. **ffmpeg filter chain**:
   - If the source frame exceeds the per-frame budget: `-vf scale=W:H,fps=N,format=rgb24` (resize first to keep fps filter's timing math correct on already-resized frames).
   - Else: `-vf fps=N,format=rgb24`.
4. `-frames:v max_frames` limits the run. The pipe is opened with `_popen` on Windows (`popen` on POSIX).
5. Read `nx*ny*3` bytes per frame, append into the bitmap's `data` vector. `mtmd_bitmap_init_from_seq` handles odd-frame padding.
6. Failure modes: ffprobe non-zero exit → log error, return nullptr. ffmpeg non-zero exit → log, return nullptr. Short read → log, return nullptr.

The extraction is implemented in `mtmd-helper.cpp::video_extract_frames` (~60 lines, after refactor). It does not invoke ffmpeg's full pipeline library — it only needs decoded RGB frames.

## Pair-chunking encoder

Qwen-VL's vision encoder is fundamentally a **two-frame** model: `temporal_patch_size=2`. The Qwen-VL paper and reference implementation stack two frames at a time, run them through two separate `patch_embeddings_*` convs, and add the results.

The upstream PR #21858 only implemented this for `nt==2` (and `nt==1` as a fallback for still images). The encoder had `GGML_ASSERT(nt <= 2)` and an early return.

### What changed

`tools/mtmd/models/qwen2vl.cpp::build_inp_with_temporal_merge`:

- Removed the `nt <= 2` cap. The encoder now loops over `npairs = nt / 2` pairs.
- For each pair, slice two frames out of the batched `inp_raw` with `ggml_view_3d` and run each through its own `patch_embeddings_0` / `patch_embeddings_1` conv. The two conv outputs are added (matching the upstream `nt==2` path).
- Pair outputs are `ggml_concat`'d along the H axis (`dim=1` in the conv2d output layout, which is `[W, H, C, B]` internally). This gives a single tensor with `h_dim = npairs * n_patches_y` and the same W/C/B as the single-pair case.
- `build()` was changed to read `h_dim` from the actual tensor shape (`inp->ne[2]` after the permute), then compute `n_pos = n_patches_x * h_dim` for all subsequent reshapes and `num_position_ids = n_pos * 4` for M-RoPE.

`tools/mtmd/models/qwen3vl.cpp` mirrors the same change (Qwen3-VL inherits `clip_graph_qwen2vl` but has its own override of the patch embeddings layout).

### Per-pair chunks in LLM integration

The encoder returns one concatenated embedding for all pairs. The LLM integration in `mtmd.cpp::add_seq_image` then splits this into one `mtmd_input_chunk` per pair:

- The encoder's pair outputs are sliced in the CLIP layer (via `clip_n_output_tokens` × `npairs` accounting in `clip.cpp`).
- `add_seq_image` allocates one `mtmd_image_tokens` per pair, each with `nt = 1` and `pos = MTMD_POS_TYPE_MROPE`.
- One `mtmd_input_chunk` per pair is appended to `cur.entries`.

**Why per-pair chunks?** Hybrid memory's `find_slot` needs a unique position per chunk (the K/V cache cell is indexed by `(seq_id, pos)`). A single multi-pair chunk would need internal position handling that the hybrid memory allocator doesn't support. The per-pair approach also matches the per-pair T-axis: each chunk advances `pos.t` by one.

**Side effect:** the encoder embeddings differ numerically between the per-pair and single-call paths (semantically equivalent, numerically different due to per-pair M-RoPE T-axis vs. shared-T for the single-call path). The encoder goldens in `tests/testdata/encoder-nt{2,4,8,64}-qwen2vl.bin` are recorded with per-pair chunking, so the test guards both the encoder graph change and the per-pair chunk split.

## M-RoPE T-axis

M-RoPE (Multi-axis Rotary Position Embedding) assigns each token four position components `(t, x, y, z)`. For a Qwen-VL model:

- `t` = temporal (which pair)
- `x` = width axis (column in the patch grid)
- `y` = height axis (row in the patch grid)
- `z` = (unused for image/video; set to 0)

### What changed

`tools/mtmd/mtmd.h`: added `int nt = 1` field to `mtmd_image_tokens` (default 1 = still image).

`tools/mtmd/mtmd.cpp`:
- `add_seq_image` sets `image_tokens->nt = 1` per chunk (since each chunk is one pair).
- `mtmd_image_tokens_get_decoder_pos` (M-RoPE branch): for `nt == 1`, `pos.t = pos_0 + i` (sequential, same as before). The `x`, `y` come from the patch grid; `z = 0`. (Each per-pair chunk has `nt == 1`, so the T-axis increments by one chunk at a time as `pos_0` advances.)
- `mtmd_image_tokens_get_n_pos` returns `max(nx, ny, nt)` for M-RoPE — for the per-pair chunks, this is `max(nx, ny, 1) = max(nx, ny)`, which is the same as a still image. Correct.

For the encoder, the per-pair M-RoPE is handled in `clip.cpp::clip_image_build_graph` (positions builder scales by `npairs` for the H and T axes; `learned_pos_embd` is tiled per pair).

## Per-frame pixel budget

The reference `qwen-vl-utils.fetch_video()` (Python) computes a per-frame max resolution based on the total pixel budget divided by the frame count. We mirror that.

### Constants (`tools/mtmd/mtmd-helper.cpp::mtmd_video_budget`)

```cpp
constexpr int VIDEO_MIN_TOKEN_NUM = 128;       // qwen-vl-utils VIDEO_MIN_TOKEN_NUM
constexpr int VIDEO_MAX_TOKEN_NUM = 768;       // qwen-vl-utils VIDEO_MAX_TOKEN_NUM
constexpr int FRAME_FACTOR        = 2;          // qwen-vl-utils FRAME_FACTOR
constexpr int VIDEO_TOTAL_PIXELS  = 24576 * 28 * 28;  // 19,267,584
constexpr int IMAGE_FACTOR_BASE   = 28;         // patch_size=14 * SPATIAL_MERGE_SIZE=2
constexpr int MIN_PIXELS = VIDEO_MIN_TOKEN_NUM * IMAGE_FACTOR_BASE * IMAGE_FACTOR_BASE;
constexpr int MAX_PIXELS = VIDEO_MAX_TOKEN_NUM * IMAGE_FACTOR_BASE * IMAGE_FACTOR_BASE;
```

### Formula (`compute_per_frame_max`)

```cpp
int upper = std::min(max_pixels, (int) ((long long) total_pixels * frame_factor / nframes));
return std::max(upper, (int) (min_pixels * 1.05));
```

i.e. per-frame pixel ceiling is `min(MAX_PIXELS, total_pixels * 2 / nframes)`, with a floor of `1.05 * MIN_PIXELS` to keep small-frame videos from collapsing to 1 token.

### How it's applied

`mtmd_helper_smart_resize(height, width, factor=28, min_pixels, max_pixels, &out_h, &out_w)` rounds the native frame dimensions down to the nearest `factor` multiple while keeping `h*w` in `[min_pixels, max_pixels]` and preserving aspect ratio. This matches `qwen_vl_utils.vision_process.smart_resize` exactly (verified by `test-smart-resize` against the Python reference for 8 cases).

If the resized `W:H` differs from the source frame's native dimensions, the ffmpeg filter chain gets `-vf scale=W:H,fps=N,format=rgb24` prepended. If no resize is needed, only `-vf fps=N,format=rgb24` is used.

### CLI overrides

The constants above are the defaults. The user can override any of them:

| Flag | Default | Matches qwen-vl-utils |
|------|---------|------------------------|
| `--video-fps` | 2.0 | `FPS` |
| `--video-min-frames` | 4 | `FPS_MIN_FRAMES` |
| `--video-max-frames` | 768 | `FPS_MAX_FRAMES` |
| `--video-min-tokens` | 128 | `VIDEO_MIN_TOKEN_NUM` |
| `--video-max-tokens` | 768 | `VIDEO_MAX_TOKEN_NUM` |
| `--video-total-pixels` | 19,267,584 | `VIDEO_TOTAL_PIXELS` |

## CLI flags

All video-related flags in `common/arg.cpp`:

| Flag | Argument | Default | Purpose |
|------|----------|---------|---------|
| `--video` | `FILE` | (none) | Video to load. Can be specified multiple times. Single-turn mode. |
| `/video` | `<path>` | (n/a) | Chat-mode command. Loads a video in an interactive session. |
| `--video-fps` | `F` | 2.0 | Sampling rate. Each pair uses 50-2000 tokens — increase `-c` for high-res/long videos. |
| `--video-min-frames` | `N` | 4 | Floor on extracted frames (qwen-vl-utils `FPS_MIN_FRAMES`); short videos are upsampled to this count. |
| `--video-max-frames` | `N` | 768 | Cap on extracted frames (qwen-vl-utils `FPS_MAX_FRAMES`); `0` = no cap. |
| `--video-min-tokens` | `N` | 128 | Per-frame minimum token count; floor for per-frame pixel budget. |
| `--video-max-tokens` | `N` | 768 | Per-frame maximum token count; ceiling for per-frame pixel budget. |
| `--video-total-pixels` | `N` | 19,267,584 | Total pixel budget for the whole video; per-frame max is `total/nframes*FRAME_FACTOR`. |

The C API entry point `mtmd_helper_bitmap_init_from_video` mirrors these parameters:

```c
MTMD_API mtmd_bitmap * mtmd_helper_bitmap_init_from_video(mtmd_context * ctx, const char * fname,
                                                           float fps, int min_frames, int max_frames,
                                                           int min_tokens, int max_tokens, int total_pixels);
```

## Context size for video (K/V cache requirement)

**The LLM K/V cache is sized for `n_ctx` tokens — one cache cell per token. Image tokens count.** For a 5-second 1920×1080 video at `--video-fps 4` (up to 20 frames = 10 pairs, each pair at the `VIDEO_MAX_TOKEN_NUM=768` ceiling → ~7680 tokens at max), `-c` must be at least that many tokens larger than the rest of the prompt.

Concrete numbers from the test corpus:

| Video | Resolution | fps | Frames | Pairs | Per-pair tokens | Total image tokens | Min `-c` |
|-------|-----------|-----|--------|-------|-----------------|-------------------|----------|
| `test.mp4` | 320×240 | 2 | 10 | 5 | ~49 | 245 | 4096 |
| `test-30s.mp4` (low-res) | 480p | 2 | 60 | 30 | ~196 | 5880 | 8192 |
| High-res test | 1920×1080 | 4 | 20 | 10 | up to 768 | 7680 | 16384 |
| Worst case | 1920×1080 | 4 | 20 | 10 | 2040 (no resize) | 20,400 | 32768 |

The per-frame pixel budget typically keeps a low-res 320×240 test video's per-pair tokens small (~49), so `-c 4096` is fine for the standard sanity test. For multi-pair or high-res videos, scale `-c` proportionally. The `--video-fps` help text flags this:

> frames per second to sample from video (default: 2.0, matches qwen-vl-utils FPS); each pair uses 50-2000 tokens — increase -c for high-res/long videos

A symptom of undersized `-c` is a runtime error from `llama_decode` ("n_batch is too large" or KV cache overflow), not garbled output. The earlier confusion during debugging ("M-RoPE misalignment?") turned out to be K/V cache size, not M-RoPE.

## Tests

| Test | Source | What it covers |
|------|--------|----------------|
| `test-mtmd-c-api` | `tests/test-mtmd-c-api.c` | C API regression: `mtmd_bitmap_init_from_seq`, `mtmd_test_video_extract`. (Original PR #21858.) |
| `test-arg-parser` | `tests/test-arg-parser.cpp` | Arg-parser cases: `--video-fps`, `--video-min-frames`, `--video-max-frames` (Task 3.1). |
| `test-mtmd-encoder-seq` | `tests/test-mtmd-encoder-seq.cpp` | Bit-identical encoder regression for `nt=2/4/8/64`. Records goldens on first run, compares on subsequent runs. Goldens in `tests/testdata/encoder-nt{2,4,8,64}-qwen2vl.bin`. Guards the pair-chunking graph change. |
| `test-mtmd-positions` | `tests/test-mtmd-positions.cpp` | M-RoPE T-axis for video pairs. Verifies `pos.t` advances per pair, `pos.x` / `pos.y` are spatial within pair, `pos.z = 0`. Skips for non-M-RoPE models. |
| `test-smart-resize` | `tests/test-smart-resize.cpp` | 8 cases of `mtmd_helper_smart_resize` against the Python `qwen-vl-utils` reference. Covers upsample to min, downscale to max, tight-max (min == max), and a 1080p test. |

Build all with `./build-cuda.ps1` and run with `ctest -L main` (or per-test executable in `build/bin/`).

## Test evidence

GPU: RTX 4090, 24 GB VRAM. CPU comparison: 170 s/image vs 0.5 s/image on GPU.

| Model | Quant | GPU | Image | Video (2 frames) | Video (10 frames, 5 pairs) | Time |
|-------|-------|-----|-------|------------------|---------------------------|------|
| Qwen3.5-2B | Q4_K_M | ✅ | ✅ | ✅ "A sunny day in a lush green park with tall trees, a wooden bench, and a white truck parked nearby." | ✅ | <2 s |
| Qwen3.6-27B | IQ4_XS | ✅ | ✅ | ✅ "this is a beautiful park with lots of trees and plants in it and there is a road near the park and there are cars on the road." | (out of scope for this iteration; needs `-c 32768`) | ~20 s load + <2 s eval |

Test video: 5 s sample mp4, 320×240 (low-res `test5s_240p.mp4` fixture; the 5 s 1080p `test.mp4` is the high-res stress test and needs `-c 8192` on the 27B model). Default flags (`--video-fps 2.0 --video-max-frames 768`) extract 10 frames (5 s × 2 fps = 10, even, no padding).

Reproduce (note: defaults are now sane, no need to pass `--video-fps` / `--video-max-frames`):

```powershell
printf '/video C:\temp\qwen-test\test5s_240p.mp4\nDescribe it.\n/quit\n' | `
  ./build/bin/Release/llama-mtmd-cli.exe `
    -m "C:\Users\yoho\.cache\lm-studio\models\unsloth\Qwen3.6-27B-MTP-GGUF\Qwen3.6-27B-IQ4_XS.gguf" `
    --mmproj "C:\Users\yoho\.cache\lm-studio\models\unsloth\Qwen3.6-27B-MTP-GGUF\mmproj-F16.gguf" `
    -ngl 99 -c 4096 -b 1024 -ub 512
```

## Known limitations

- **Even frame counts only.** `qwen2vl.cpp::build_inp_with_temporal_merge` requires `nt % 2 == 0` (Qwen-VL's `temporal_patch_size=2`). `mtmd_helper_bitmap_init_from_video` rounds odd `nt` down to even via `nframes_est -= 1` and logs a warning, matching `qwen-vl-utils.fetch_video`'s `floor_by_factor(nframes, 2)`. Odd `nt` from `--video-fps 2.5` × 5 s → 13 raw → 12 after the floor. No assert; just a `LOG_WRN`.
- **M-RoPE is 3D for video, 2D for stills.** `mtmd_image_tokens_get_decoder_pos` for `MTMD_POS_TYPE_MROPE` now writes a real T-axis per pair (this is the work in commit `d2286815d`). Still images (`nt == 1`) keep `pos.t = 0` since there's only one "pair". `pos.z` is always 0.
- **No MTP / ngram-mod interaction tested.** The user's production server uses `--spec-type ngram-mod,draft-mtp`. The 27B test above skipped speculative decoding. May need additional position handling for MTP draft to see video positions correctly.
- **No window attention for video.** `qwen2vl.cpp::build()` asserts `!use_window_attn || nt == 1` — the window attention mask is computed per-frame and not extended to the video (npairs) case. Models with `n_wa_pattern > 0` (currently only some Qwen2-VL variants) cannot be used for video.
- **K/V cache scales with `n_ctx`.** See [Context size for video](#context-size-for-video-kv-cache-requirement) for the formula. Undersized `-c` gives a runtime error, not garbled output.
- **Server-side not implemented.** Tracking upstream [issue #18389](https://github.com/ggml-org/llama.cpp/issues/18389). The CLI work in this branch is the foundation; Phase 6a/6b (server + WebUI) is deferred until Phases 1-5 are stable.

## Discovered during implementation

- **M-RoPE T-axis vs. K/V cache: easy to confuse.** During Task 1.4 debugging, an early failure ("multi-pair video produces garbled tokens") looked like M-RoPE misalignment. Investigation traced it to `llama_decode` failing silently when the K/V cache ran out of cells — the LLM was reusing a partial cache. The M-RoPE T-axis is correct (`pos.t` advances per pair); the issue was `-c` being too small. See [Context size for video](#context-size-for-video-kv-cache-requirement).
- **Mamba state investigation (recurrent state is preserved correctly).** As part of the broader debugging, we verified that the Mamba-style recurrent state in the LLM (if applicable) is preserved correctly across token batches — i.e., the issue was not recurrent state loss, it was the K/V cache. This applies to models with hybrid attention + Mamba layers.
- **Encoder goldens drift after per-frame budget change.** Task 2.1's per-frame budget change altered the per-frame resolution used by the encoder, which altered the encoder output. All four `encoder-nt*-qwen2vl.bin` goldens had to be re-recorded. The test scaffold handles this: first run records, second run verifies.
- **Per-pair M-RoPE differs from single-call.** The encoder returns numerically-different embeddings depending on whether it was called once with `nt=4` (single call, shared T-axis) or twice with `nt=2` (per-pair, T-axis advances per call). Semantically equivalent (same T-axis semantics), numerically different (different attention patterns). The encoder goldens are recorded with per-pair chunking, so they cover the production path.

## Follow-up work (in priority order)

1. **Server-side wiring** (issue #18389). Mirror `mtmd_helper_bitmap_init_from_video` into the OpenAI-compatible `/v1/chat/completions` handler. Requires server to accept a base64 video or URL + ffmpeg invocation. **Phase 6a.**
2. **WebUI integration** for video upload. Depends on the server's `/v1/media/upload` endpoint and the `video_url` content type. **Phase 6b.**
3. **Position 3D M-RoPE quality benchmark** to confirm the T-axis implementation doesn't degrade output quality for the user's typical prompts. (The T-axis is now implemented; this is a quality sanity check, not a fix.)
4. **3-way clean rebase onto `origin/master`** so this work is drop-in for an upstream PR.
5. **Window attention for video** — extend the `n_wa_pattern` mask to cover the per-pair dim. Required for Qwen2-VL variants with `n_wa_pattern > 0` (none of the user's current models, but blocks broader Qwen2-VL support).

## PR description skeleton (for the human to write)

The actual PR text **must be human-written** per the project's `AGENTS.md` policy ("AI-written PR descriptions or commit messages... will result in immediate PR closure"). The skeleton below is the content the human should cover; the wording, framing, and disclosure are theirs.

- **Title**: `mtmd: full-length video support (encoder pair-chunking + qwen-vl-utils budget)` (or similar)
- **What**: extends `--video` to arbitrary even `nt`; adds M-RoPE T-axis; adds per-frame pixel budget matching `qwen-vl-utils.fetch_video()`; adds `--video-min/max-tokens`, `--video-total-pixels`, `--video-min-frames`; sane CLI defaults.
- **Why**: upstream tracking issue #18389; the user needs CLI full-length video for Qwen3-VL.
- **What was carried in from upstream**: cite PR #21858 and commit `c5b682b`.
- **What was fixed in the port**: two upstream bugs (dispatch + assert) that block the new code path; odd `nt` rounding to align with qwen-vl-utils `FRAME_FACTOR=2`.
- **What was added locally**:
  - Pair-chunking encoder (`qwen2vl.cpp`, `qwen3vl.cpp`) for arbitrary even `nt`.
  - Per-pair chunks in LLM integration (`mtmd.cpp::add_seq_image`).
  - M-RoPE T-axis (`mtmd_image_tokens_get_decoder_pos`, `image_tokens->nt`).
  - Per-frame pixel budget (`mtmd-helper.cpp::compute_per_frame_max`, `mtmd_helper_smart_resize`).
  - CLI flags (`--video-min/max-tokens`, `--video-total-pixels`, `--video-min-frames`).
  - CLI default updates (`--video-fps 1.0 → 2.0`, `--video-max-frames 2 → 768`).
  - K/V cache size documentation in `--video-fps` help text and this doc.
- **Test evidence**: encoder goldens for `nt=2/4/8/64` (bit-identical regression), M-RoPE position test, smart_resize against Python reference (8 cases), end-to-end CLI on Qwen3.5-2B (10 frames, 5 pairs, default flags).
- **Known limit**: even-frame constraint (qwen-vl-utils aligned); window attention not extended to video; server-side not implemented (issue #18389).
- **Disclosure**: note AI assistance was used for mechanical porting + finding the two upstream bugs + the encoder goldens; design decisions, M-RoPE T-axis implementation, and final wording are human.
- **Maintainer alignment**: this is structured to be mergeable as "carry PR #21858 + small fixes + encoder extension" rather than a competing design.
