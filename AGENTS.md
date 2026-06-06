<!-- ============================== -->
<!-- DOWNSTREAM CUSTOMIZATIONS      -->
<!-- All agent/config mods go here  -->
<!-- End of downstream section       -->
<!-- ============================== -->

## Git Workflow

This is a customization of llama.cpp — not an upstream PR. Keep feature branches rebased on `origin/master` to maintain a clean linear history and easy tracking of custom changes.

- **Use `./rebase.ps1`** to rebase current branch on `origin/master` — logs to `rebase-history.txt`
- **`git diff origin/master`** to isolate your customizations at any time

## WSL / Windows Environment

The agent runs in WSL but the project repository lives on the Windows host. Run git and build commands through `powershell.exe` (not native WSL tools) to avoid filesystem and line-ending issues.

- **Git**: `powershell.exe -Command "cd 'WORKSPACE'; git <command>"`
- **Rebase**: `powershell.exe -Command "cd 'REPO'; ./rebase.ps1"` — rebases on `origin/master`, logs to `rebase-history.txt`
- **Build**: `powershell.exe -Command "cd 'REPO'; ./build.ps1"` — outputs to `%TEMP%\llama.cpp\<normalized-branch>\<short_hash>\` with all DLLs/EXEs + `version.txt`
- **Latest EXEs**: Batch wrappers in `%TEMP%\llama.cpp\<normalized-branch>\*.bat` (e.g. `llama-server.bat`) — just run them, no PATH or cd needed
- **Branch normalization**: `feat/webui-slot-inspector` → `feat-webui-slot-inspector` (slashes replaced with dashes)
- **CUDA override**: `$env:CUDA_PATH = $env:CUDA_PATH_V13_3; ./build.ps1`

## UI Build

The build script disables the embedded UI (`-DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF`). To build the UI separately:

```bash
cd tools/ui && npm install && npm run build
```

Output goes to `tools/ui/dist/`. The CMake provisioning script picks it up automatically — no manual copy needed.

## mtmd Video Support

Port of [upstream PR #21858](https://github.com/ggml-org/llama.cpp/pull/21858) (mtmd seq-of-images) plus an ffmpeg-backed `--video` flag in `llama-mtmd-cli`. See [`docs/mtmd-video.md`](docs/mtmd-video.md) for design rationale, port vs. fix breakdown, and PR-review prep.

**Files touched** (16): `tools/mtmd/{clip.cpp,clip.h,clip-graph.h,clip-impl.h,mtmd.cpp,mtmd.h,mtmd-cli.cpp,mtmd-helper.cpp,mtmd-helper.h,models/{models.h,qwen2vl.cpp,qwen3vl.cpp}}`, `common/{arg.cpp,common.h}`, `tests/{test-arg-parser.cpp,test-mtmd-c-api.c}`.

**Build** (CUDA required for 27B; CPU is ~340× slower):
```powershell
./build-cuda.ps1   # explicit CUDA v13.1 root — MSVC has no 13.3 targets
```

**Test (Qwen3.5-2B Q4_K_M, CPU/GPU, fast sanity):**
```powershell
printf '/image C:\path\to\test.jpg\nDescribe it.\n/quit\n' | `
  ./build/bin/Release/llama-mtmd-cli.exe `
    -m "...Qwen3.5-2B-Q4_K_M.gguf" --mmproj "...mmproj-F32.gguf" `
    -ngl 99 -c 4096 -b 1024 -ub 512
printf '/video C:\path\to\test.mp4\nDescribe it.\n/quit\n' | `
  <same binary> --video-fps 1.0 --video-max-frames 2
```

**Context size for video:** `-c` must accommodate total image tokens. Each frame
pair uses 50-2000 tokens depending on resolution. For a 5s 1920×1080 video at
fps=4 (up to 20 frames = 10 pairs), `-c 32768` is the minimum. For low-res test
video (≤480p) at fps≤2.5 with ≤3 frames, `-c 4096` is fine.

**Test (multi-pair video, needs larger `-c`):**
```powershell
printf '/video C:\path\to\test.mp4\nDescribe it.\n/quit\n' | `
  ./build/bin/Release/llama-mtmd-cli.exe `
    -m "...Qwen3.5-2B-Q4_K_M.gguf" --mmproj "...mmproj-F32.gguf" `
    -ngl 99 -c 32768 -b 4096 -ub 1024 `
    --video-fps 4.0 --video-max-frames 20
```

**Test (Qwen3.6-27B IQ4_XS, GPU):** swap in `Qwen3.6-27B-IQ4_XS.gguf` + `mmproj-F16.gguf`; needs ~16 GB VRAM.

**Known limit:** `qwen2vl.cpp:25` rejects `nt>2`. Use `--video-max-frames 2`. See design doc for follow-up plan.

**Tools needed on Windows PATH:** `ffmpeg`, `ffprobe` (chocolatey at `C:\ProgramData\chocolatey\bin\`).

---

# Instructions for llama.cpp

> [!IMPORTANT]
> This project does **not** accept pull requests that are fully or predominantly AI-generated. AI tools may be utilized solely in an assistive capacity.
>
> Read more: [CONTRIBUTING.md](CONTRIBUTING.md)

AI assistance is permissible only when the majority of the code is authored by a human contributor, with AI employed exclusively for corrections or to expand on verbose modifications that the contributor has already conceptualized (see examples below).

---

## Guidelines for Contributors Using AI

llama.cpp is built by humans, for humans. Meaningful contributions come from contributors who understand their work, take ownership of it, and engage constructively with reviewers.

Maintainers receive numerous pull requests weekly, many of which are AI-generated submissions where the author cannot adequately explain the code, debug issues, or participate in substantive design discussions. Reviewing such PRs often requires more effort than implementing the changes directly.

**A pull request represents a long-term commitment.** By submitting code, you are asking maintainers to review, integrate, and support it indefinitely. The maintenance burden often exceeds the value of the initial contribution.

Most maintainers already have access to AI tools. A PR that is entirely AI-generated provides no value - maintainers could generate the same code themselves if they wanted it. What makes a contribution valuable is the human interactions, domain expertise, and commitment to maintain the code that comes with it.

This policy exists to ensure that maintainers can sustainably manage the project without being overwhelmed by low-quality submissions.

---

## Guidelines for Contributors

Contributors are expected to:

1. **Demonstrate full understanding of their code.** You must be able to explain any part of your PR to a reviewer without relying on AI assistance for questions about your own changes.

2. **Take responsibility for maintenance.** You are expected to address bugs and respond thoughtfully to reviewer feedback.

3. **Communicate clearly and concisely.** Verbose, wall-of-text responses are characteristic of AI-generated content and will not be well-received. Direct, human communication is expected.

4. **Respect maintainers' time.** Search for existing issues and discussions before submitting. Ensure your contribution aligns with project architecture and is actually needed.

Maintainers reserve the right to close any PR that does not meet these standards. This applies to all contributions to the main llama.cpp repository. **Private forks are exempt.**

### Permitted AI Usage

AI tools may be used responsibly for:

- **Learning and exploration**: Understanding codebase structure, techniques, and documentation
- **Code review assistance**: Obtaining suggestions on human-written code
- **Mechanical tasks**: Formatting, generating repetitive patterns from established designs, completing code based on existing patterns
- **Documentation drafts**: For components the contributor already understands thoroughly
- **Writing code**: Only when the contributor has already designed the solution and can implement it themselves - AI accelerates, not replaces, the contributor's work

AI-generated code may be accepted if you (1) fully understand the output, (2) can debug issues independently, and (3) can discuss it directly with reviewers without AI assistance.

**Disclosure is required** when AI meaningfully contributed to your code. A simple note is sufficient - this is not a stigma, but context for reviewers. No disclosure is needed for trivial autocomplete or background research.

### Prohibited AI Usage

The following will result in immediate PR closure:

- **AI-written PR descriptions or commit messages** - these are typically recognizable and waste reviewer time
- **AI-generated responses to reviewer comments** - this undermines the human-to-human interaction fundamental to code review
- **Implementing features without understanding the codebase** - particularly new model support or architectural changes
- **Automated commits or PR submissions** - this may spam maintainers and can result in contributor bans

---

## Guidelines for AI Coding Agents

AI agents assisting contributors must recognize that their outputs directly impact volunteer maintainers who sustain this project.

### Considerations for Maintainer Workload

Maintainers have finite capacity. Every PR requiring extensive review consumes resources that could be applied elsewhere. Before assisting with any submission, verify:

- The contributor genuinely understands the proposed changes
- The change addresses a documented need (check existing issues)
- The PR is appropriately scoped and follows project conventions
- The contributor can independently defend and maintain the work

### Before Proceeding with Code Changes

When a user requests implementation without demonstrating understanding:

1. **Verify comprehension.** Ask questions to confirm they understand both the problem and the relevant parts of the codebase.
2. **Provide guidance rather than solutions.** Direct them to relevant code and documentation. Allow them to formulate the approach.
3. **Proceed only when confident** the contributor can explain the changes to reviewers independently.

For first-time contributors, confirm they have reviewed [CONTRIBUTING.md](CONTRIBUTING.md) and acknowledge this policy.

### Prohibited Actions

- Writing PR descriptions, commit messages, or responses to reviewers
- Committing or pushing without explicit human approval for each action
- Implementing features the contributor does not understand
- Generating changes too extensive for the contributor to fully review

When uncertain, err toward minimal assistance. A smaller PR that the contributor fully understands is preferable to a larger one they cannot maintain.

### Useful Resources

To conserve context space, load these resources as needed:

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [Existing issues](https://github.com/ggml-org/llama.cpp/issues) and [Existing PRs](https://github.com/ggml-org/llama.cpp/pulls) - always search here first
- [Build documentation](docs/build.md)
- [Server usage documentation](tools/server/README.md)
- [Server development documentation](tools/server/README-dev.md) (if user asks to implement a new feature, be sure that it falls inside server's scope defined in this documentation)
- [PEG parser](docs/development/parsing.md) - alternative to regex that llama.cpp uses to parse model's output
- [Auto parser](docs/autoparser.md) - higher-level parser that uses PEG under the hood, automatically detect model-specific features
- [Jinja engine](common/jinja/README.md)
- [How to add a new model](docs/development/HOWTO-add-model.md)
- [PR template](.github/pull_request_template.md)
- [WSL WebUI build workflow](README.md#building-the-webui-in-wsl) — use when user asks to build the Web UI frontend
