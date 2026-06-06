#include "llama.h"
#include "mtmd.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <vector>

static int test_video_positions(const char * model_path, const char * mmproj_path, uint32_t nt) {
    if (nt < 2 || nt % 2 != 0) {
        std::fprintf(stderr, "FAIL: nt must be even and >= 2, got %u\n", nt);
        return 1;
    }
    const uint32_t npairs = nt / 2;

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0;
    llama_model * text_model = llama_model_load_from_file(model_path, mparams);
    if (!text_model) {
        std::fprintf(stderr, "FAIL: llama_model_load_from_file (%s)\n", model_path);
        return 1;
    }

    mtmd_context_params params = mtmd_context_params_default();
    params.use_gpu = false;
    params.n_threads = 4;
    mtmd_context * ctx = mtmd_init_from_file(mmproj_path, text_model, params);
    if (!ctx) {
        std::fprintf(stderr, "FAIL: mtmd_init_from_file\n");
        llama_model_free(text_model);
        return 1;
    }

    if (!mtmd_decode_use_mrope(ctx)) {
        std::fprintf(stderr, "SKIP: model does not use M-RoPE\n");
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 0;
    }

    const uint32_t nx = 224, ny = 224;
    const size_t frame_bytes = (size_t) nx * ny * 3;
    std::vector<unsigned char> data(frame_bytes * nt);
    for (uint32_t f = 0; f < nt; f++) {
        for (uint32_t y = 0; y < ny; y++) {
            for (uint32_t x = 0; x < nx; x++) {
                size_t i = (f * frame_bytes) + ((size_t) y * nx + x) * 3;
                data[i + 0] = (unsigned char) (f * 30);
                data[i + 1] = (unsigned char) (x & 0xFF);
                data[i + 2] = (unsigned char) (y & 0xFF);
            }
        }
    }

    mtmd_bitmap * bitmap = mtmd_bitmap_init_from_seq(nx, ny, nt, data.data());
    if (!bitmap) {
        std::fprintf(stderr, "FAIL: mtmd_bitmap_init_from_seq\n");
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    if (!chunks) {
        std::fprintf(stderr, "FAIL: mtmd_input_chunks_init\n");
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    mtmd_input_text text;
    text.text          = mtmd_default_marker();
    text.add_special   = false;
    text.parse_special = false;
    const mtmd_bitmap * bitmaps[] = { bitmap };
    int rc = mtmd_tokenize(ctx, chunks, &text, bitmaps, 1);
    if (rc != 0) {
        std::fprintf(stderr, "FAIL: mtmd_tokenize (rc=%d)\n", rc);
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    std::vector<const mtmd_input_chunk *> image_chunks;
    size_t total_n_tokens = 0;
    size_t first_nx = 0, first_ny = 0;
    for (size_t i = 0; i < mtmd_input_chunks_size(chunks); i++) {
        const mtmd_input_chunk * c = mtmd_input_chunks_get(chunks, i);
        if (mtmd_input_chunk_get_type(c) != MTMD_INPUT_CHUNK_TYPE_IMAGE) {
            continue;
        }
        const mtmd_image_tokens * it = mtmd_input_chunk_get_tokens_image(c);
        if (!it) {
            std::fprintf(stderr, "FAIL: image_tokens is null at chunk %zu\n", i);
            mtmd_input_chunks_free(chunks);
            mtmd_bitmap_free(bitmap);
            mtmd_free(ctx);
            llama_model_free(text_model);
            return 1;
        }
        if (image_chunks.empty()) {
            first_nx = mtmd_image_tokens_get_nx(it);
            first_ny = mtmd_image_tokens_get_ny(it);
        } else {
            if (mtmd_image_tokens_get_nx(it) != first_nx || mtmd_image_tokens_get_ny(it) != first_ny) {
                std::fprintf(stderr, "FAIL: image chunk %zu has nx=%zu ny=%zu, expected nx=%zu ny=%zu\n",
                             i, mtmd_image_tokens_get_nx(it), mtmd_image_tokens_get_ny(it),
                             first_nx, first_ny);
                mtmd_input_chunks_free(chunks);
                mtmd_bitmap_free(bitmap);
                mtmd_free(ctx);
                llama_model_free(text_model);
                return 1;
            }
        }
        total_n_tokens += mtmd_image_tokens_get_n_tokens(it);
        image_chunks.push_back(c);
    }
    if (image_chunks.empty()) {
        std::fprintf(stderr, "FAIL: no image chunks found\n");
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }
    if (image_chunks.size() != npairs) {
        std::fprintf(stderr, "FAIL: expected %u image chunks (one per pair), got %zu\n",
                     npairs, image_chunks.size());
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    const size_t n_per_pair = first_nx * first_ny;
    std::fprintf(stderr, "INFO: nt=%u npairs=%u n_chunks=%zu n_tokens=%zu nx=%zu ny=%zu n_per_pair=%zu\n",
                 nt, npairs, image_chunks.size(), total_n_tokens, first_nx, first_ny, n_per_pair);

    if (total_n_tokens != n_per_pair * npairs) {
        std::fprintf(stderr, "FAIL: total_n_tokens=%zu != n_per_pair(%zu) * npairs(%u) = %zu\n",
                     total_n_tokens, n_per_pair, npairs, n_per_pair * npairs);
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    const llama_pos pos_0_base = 100;
    llama_pos n_pos_cursor = pos_0_base;
    bool saw_nonzero_t = false;
    bool saw_zero_t    = false;
    uint32_t prev_t = UINT32_MAX;
    for (size_t ci = 0; ci < image_chunks.size(); ci++) {
        const mtmd_input_chunk * c = image_chunks[ci];
        const mtmd_image_tokens * it = mtmd_input_chunk_get_tokens_image(c);
        const size_t n_tokens_in_chunk = mtmd_image_tokens_get_n_tokens(it);
        const llama_pos pos_0 = n_pos_cursor;
        const llama_pos n_pos = mtmd_input_chunk_get_n_pos(c);
        for (size_t i = 0; i < n_tokens_in_chunk; i++) {
            struct mtmd_decoder_pos pos = mtmd_image_tokens_get_decoder_pos(it, pos_0, i);
            const uint32_t got_t       = (uint32_t)(pos.t - pos_0);
            const uint32_t got_x       = (uint32_t)(pos.x - pos_0);
            const uint32_t got_y_within = (uint32_t)(pos.y - pos_0);

            if (got_t != 0) {
                std::fprintf(stderr, "FAIL: chunk %zu i=%zu pos.t=%u (expected t-offset 0 within chunk, got %u)\n",
                             ci, i, (uint32_t)pos.t, got_t);
                mtmd_input_chunks_free(chunks);
                mtmd_bitmap_free(bitmap);
                mtmd_free(ctx);
                llama_model_free(text_model);
                return 1;
            }
            const uint32_t expected_x     = (uint32_t)(i % first_nx);
            const uint32_t expected_y_within = (uint32_t)((i / first_nx) % first_ny);
            if (got_x != expected_x) {
                std::fprintf(stderr, "FAIL: chunk %zu i=%zu pos.x=%u (x=%u) expected x=%u\n",
                             ci, i, (uint32_t)pos.x, got_x, expected_x);
                mtmd_input_chunks_free(chunks);
                mtmd_bitmap_free(bitmap);
                mtmd_free(ctx);
                llama_model_free(text_model);
                return 1;
            }
            if (got_y_within != expected_y_within) {
                std::fprintf(stderr, "FAIL: chunk %zu i=%zu pos.y=%u (y_within=%u) expected y_within=%u\n",
                             ci, i, (uint32_t)pos.y, got_y_within, expected_y_within);
                mtmd_input_chunks_free(chunks);
                mtmd_bitmap_free(bitmap);
                mtmd_free(ctx);
                llama_model_free(text_model);
                return 1;
            }
        }
        const uint32_t chunk_t = (uint32_t)(pos_0 - pos_0_base);
        if (chunk_t == 0) {
            saw_zero_t = true;
        } else {
            saw_nonzero_t = true;
        }
        if (chunk_t != prev_t && ci > 0 && chunk_t <= prev_t) {
            std::fprintf(stderr, "FAIL: T-axis did not strictly advance across chunks (chunk %zu t=%u, prev=%u)\n",
                         ci, chunk_t, prev_t);
            mtmd_input_chunks_free(chunks);
            mtmd_bitmap_free(bitmap);
            mtmd_free(ctx);
            llama_model_free(text_model);
            return 1;
        }
        prev_t = chunk_t;
        n_pos_cursor += n_pos;
    }

    if (npairs > 1 && !saw_nonzero_t) {
        std::fprintf(stderr, "FAIL: expected non-zero T values for npairs=%u, but all chunks had t-offset 0\n", npairs);
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }
    if (npairs > 1 && !saw_zero_t) {
        std::fprintf(stderr, "FAIL: expected to see pair=0 chunk for npairs=%u, but none found\n", npairs);
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    mtmd_input_chunks_free(chunks);
    mtmd_bitmap_free(bitmap);
    mtmd_free(ctx);
    llama_model_free(text_model);
    std::fprintf(stderr, "OK: video positions nt=%u T-axis advances per pair (saw_zero=%d saw_nonzero=%d)\n",
                 nt, (int) saw_zero_t, (int) saw_nonzero_t);
    return 0;
}

int main(int argc, char ** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: %s model.gguf mmproj.gguf nt\n", argv[0]);
        return 1;
    }
    const char * model = argv[1];
    const char * mmproj = argv[2];
    uint32_t nt = (uint32_t) std::atoi(argv[3]);

    llama_backend_init();

    int rc = test_video_positions(model, mmproj, nt);

    llama_backend_free();
    return rc;
}
