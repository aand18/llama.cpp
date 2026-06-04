# mtmd Video Support — Design & Port Notes

Personal fork's port of upstream PR [#21858](https://github.com/ggml-org/llama.cpp/pull/21858) ("mtmd seq-of-images") plus a ffmpeg-backed `--video` flag in `llama-mtmd-cli`. Targets Qwen3-VL (and Qwen2.5-VL) since the user already runs Qwen3.6-27B in production.

This document is the design/rationale companion to the code. **For agent-facing notes (build commands, test invocations, known limits), see `AGENTS.md`.** For the actual diff, see the commits on `feature/qwen36-video-support-isolated` (`dd2646d76`, `920a0f075`, `8fdd7a72b`).

## Goal

Add video input to `llama-mtmd-cli` so the user can pass a short clip (mp4/mov/etc.) and ask the model to describe it. The user already has the Qwen3.6-27B MTP GGUF + mmproj locally; this is a CLI feature, not a server feature (server-side tracking is [issue #18389](https://github.com/ggml-org/llama.cpp/issues/18389)).

## Why this approach (over alternatives)

Three paths were considered:

1. **Port upstream PR #21858** (chosen). Maintainer ngxson authored it and it's tracked in his "hot" [issue #18389](https://github.com/ggml-org/llama.cpp/issues/18389). It matches the maintainer's stated direction: `nt` field on `mtmd_bitmap`, `clip_model_supports_seq_input()` gate, `add_seq_image()` dispatcher, ffmpeg via subprocess.
2. **[Cobdog/llama-video](https://github.com/Cobdog/llama-video)** third-party fork. Diverges from the maintainer's plan: introduces `MTMD_POS_TYPE_VIDEO` and packs 6 frames into one 6-channel super-frame. More invasive, harder to reconcile with mainline.
3. Hand-rolled. Out of scope; duplicates maintainer effort.

Chose #1 because (a) it tracks the maintainer's roadmap, (b) the diff is small once the foundation is in, (c) it composes cleanly with the existing `add_image` path.

## What was ported vs. what was added locally

### Ported from upstream PR #21858 (cleanup commit `c5b682b`)

Five files applied cleanly to `local/integrated`:

- `tools/mtmd/clip-graph.h` — `clip_graph.nt = 1` field
- `tools/mtmd/clip-impl.h` — `clip_image_f32_batch.is_seq = true` field
- `tools/mtmd/models/models.h` — `clip_graph_qwen3vl` inherits `clip_graph_qwen2vl`; `build_inp_with_temporal_merge` decl
- `tools/mtmd/models/qwen2vl.cpp` — `build_inp_with_temporal_merge()` body (handles `nt==1`, `nt==2`)
- `tools/mtmd/models/qwen3vl.cpp` — switches to `build_inp_with_temporal_merge()`

Six files had conflicts (20 hunks total) due to local divergence on HunyuanVL. Resolution strategy: preserve local HunyuanVL additions, apply patch intent for seq/nt fields.

### Two bugs fixed in the PR itself

These are **upstream PR bugs** that would block every seq bitmap. Without these fixes, the patch is dead code.

- **`mtmd.cpp:774` — missing dispatch.** The cleanup commit accidentally removed `if (bitmap->nt >= 2) return add_seq_image(bitmap);` from `add_media()`. Without it, every video bitmap silently degrades to single-image preprocessing. Restored.
- **`clip.cpp:847` — unconditional assert.** `clip_image_build_graph` starts with `GGML_ASSERT(imgs.entries.size() == 1 && "n_batch > 1 is not supported")`, but the patch sets `builder->nt = imgs.entries.size()` at the end — repurpose batch dim as temporal. The assert blocks batch>1 outright, so the new code path was unreachable. Fixed by skipping the assert when `clip_model_supports_seq_input()` is true (currently `PROJECTOR_TYPE_QWEN2VL/QWEN25VL/QWEN3VL`). The dispatcher in `clip_image_batch_encode` already short-circuits `batch>1` for non-seq models, so reaching the assert with batch>1 implies the model can handle it.

### Added locally

- `mtmd_helper_bitmap_init_from_video(ctx, fname, fps, max_frames)` in `mtmd-helper.{h,cpp}`. `ffprobe` for native dimensions, `ffmpeg` subprocess (`popen`) for raw RGB24 extraction at target fps, then `mtmd_bitmap_init_from_seq` constructs the bitmap. No FFmpeg linking — keeps the binary lean and respects the no-FFmpeg-CGO policy in this fork.
- `--video` / `--video-fps` / `--video-max-frames` flags in `common/{arg.cpp,common.h}`.
- `mtmd-cli.cpp`: `load_video()` method, wired into both single-turn mode and chat-mode `/video <path>` command.
- `build-cuda.ps1`: explicit `CUDA_TOOLKIT_ROOT_DIR=v13.1` because MSVC BuildTools 2022 ships only 12.6 + 13.1 `BuildCustomizations`. Without the override, CMake finds v13.3 (newest on disk) but MSBuild invokes v13.1 nvcc, producing "CUDA compiler and CUDA toolkit headers are incompatible" on every `.cu`.
- `test-arg-parser.cpp` + `test-mtmd-c-api.c`: arg-parsing cases and C API smoke for `mtmd_bitmap_init_from_seq` / `mtmd_test_video_extract`.

## ffmpeg extraction design

Constraints: no FFmpeg linking (binary size + no GPL/LGPL in the main binary), and Windows process must use a real shell pipe. Approach:

1. `ffprobe` to get native width/height (fast, no decode).
2. `ffmpeg -hide_banner -loglevel error -i INPUT -vf "fps=N,format=rgb24" -f rawvideo -` to stream RGB24 to stdout. `-frames:v max_frames` limits the run. The pipe is opened with `_popen` on Windows (`popen` on POSIX).
3. Read `nx*ny*3` bytes per frame, append into the bitmap's `data` vector. `mtmd_bitmap_init_from_seq` handles odd-frame padding.
4. Failure modes: ffprobe non-zero exit → log error, return nullptr. ffmpeg non-zero exit → log, return nullptr. Short read → log, return nullptr.

The extraction is implemented in `mtmd-helper.cpp` (~127 lines). It does not invoke ffmpeg's full pipeline library — it only needs decoded RGB frames.

## Test evidence

GPU: RTX 4090, 24 GB VRAM. CPU comparison: 170 s/image vs 0.5 s/image on GPU.

| Model | Quant | GPU | Image | Video (2 frames) | Time |
|-------|-------|-----|-------|------------------|------|
| Qwen3.5-2B | Q4_K_M | ✅ | ✅ | ✅ "A sunny day in a lush green park with tall trees, a wooden bench, and a white truck parked nearby." | <2 s |
| Qwen3.6-27B | IQ4_XS | ✅ | ✅ | ✅ "this is a beautiful park with lots of trees and plants in it and there is a road near the park and there are cars on the road." | ~20 s load + <2 s eval |

Test video: 5 s sample mp4, 320×240, downloaded from `download.samplelib.com/mp4/sample-5s.mp4`.

Reproduce:

```powershell
printf '/video C:\temp\qwen-test\test.mp4\nDescribe it.\n/quit\n' | `
  ./build/bin/Release/llama-mtmd-cli.exe `
    -m "C:\Users\yoho\.cache\lm-studio\models\unsloth\Qwen3.6-27B-MTP-GGUF\Qwen3.6-27B-IQ4_XS.gguf" `
    --mmproj "C:\Users\yoho\.cache\lm-studio\models\unsloth\Qwen3.6-27B-MTP-GGUF\mmproj-F16.gguf" `
    -ngl 99 -c 4096 -b 1024 -ub 512 --video-fps 1.0 --video-max-frames 2
```

## Known limitations

- **`nt<=2` encoder cap.** `qwen2vl.cpp:25` rejects `nt>2` (Qwen-VL's `temporal_patch_size=2`). `--video-max-frames 4` asserts. Upstream PR #21858 comment: "we only support even frames for now". Fix path: chunk in `add_seq_image` (split a 4-frame bitmap into two 2-frame chunks, add as separate `mtmd_input_chunk`s), or extend `qwen2vl.cpp` to stack multiple temporal convs. Out of scope for this WIP.
- **M-RoPE is 2D, not 3D.** `mtmd_image_tokens_get_decoder_pos` for `MTMD_POS_TYPE_MROPE` writes `(t=pos_0, x=…, y=…, z=0)`. The `t` and `z` are placeholders. True 3D M-RoPE would assign `t` per-frame and the text model would interleave. Not investigated whether this affects Qwen3.6 output quality.
- **No MTP / ngram-mod interaction tested.** The user's production server uses `--spec-type ngram-mod,draft-mtp`. The 27B test above skipped speculative decoding. May need additional position handling for MTP draft to see video positions correctly.
- **Server-side not implemented.** Tracking upstream [issue #18389](https://github.com/ggml-org/llama.cpp/issues/18389).
- **`mtmd_image_tokens_get_n_pos`** returns `max(nx, ny)` for MROPE — does not include the temporal dim. For `nt=2` this happens to be correct (frames share a 2D grid), but for `nt>2` it would under-count.
- **Odd frame counts are rounded down to even** (matching qwen-vl-utils `FRAME_FACTOR=2`). If `ffmpeg ... fps=N` produces an odd `nt` (e.g. `fps=2.5` × 5 s → 13 raw → 12 after fix), the helper drops the trailing frame and logs a `LOG_WRN`. This keeps the `qwen2vl.cpp:25` `nt<=2` constraint and the upstream temporal-pair assumption satisfied without an extra argument. Behaviour mirrors the official `qwen3-vl-utils.fetch_video()` `floor_by_factor(nframes, 2)` step.

## Follow-up work (in priority order)

1. **`nt>2` support.** Chunk `add_seq_image` into 2-frame windows. Smallest change, biggest user-facing win. Test with 4/6/8 frame inputs on Qwen3.5-2B.
2. **Server-side wiring** (issue #18389). Mirror the `mtmd_helper_bitmap_init_from_video` API into the OpenAI-compatible `/v1/chat/completions` handler. Requires server to accept a base64 video or URL + ffmpeg invocation.
3. **Position 3D M-RoPE** if Qwen3.6 output quality is degraded relative to 2D. (Need a quality benchmark to confirm it's actually a problem first.)
4. **3-way clean rebase onto `origin/master`** so this work is drop-in for an upstream PR.

## PR description skeleton (for the human to write)

The actual PR text **must be human-written** per the project's `AGENTS.md` policy ("AI-written PR descriptions or commit messages... will result in immediate PR closure"). The skeleton below is the content the human should cover; the wording, framing, and disclosure are theirs.

- **Title**: `mtmd: video input support via PR #21858 + ffmpeg extraction` (or similar)
- **What**: adds `--video` to `llama-mtmd-cli`; ffmpeg subprocess extracts frames; new seq bitmap API
- **Why**: upstream tracking issue #18389; the maintainer's planned approach
- **What was carried in from upstream**: cite PR #21858 and commit `c5b682b`
- **What was fixed in the port**: two bugs (dispatch + assert) that block the new code path, plus odd `nt` rounding to align with qwen-vl-utils `FRAME_FACTOR=2`
- **What was added locally**: ffmpeg extraction, CLI flags, CUDA v13.1 build fix
- **Test evidence**: table above (2B + 27B on GPU)
- **Known limit**: `nt<=2` encoder cap; cite PR comment "we only support even frames for now"
- **Disclosure**: note AI assistance was used for mechanical porting + finding the two upstream bugs; design decisions and final wording are human
- **Maintainer alignment**: this is structured to be mergeable as "carry PR #21858 + small fixes" rather than a competing design
