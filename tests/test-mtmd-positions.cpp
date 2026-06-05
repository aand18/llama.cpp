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

    const mtmd_input_chunk * image_chunk = nullptr;
    for (size_t i = 0; i < mtmd_input_chunks_size(chunks); i++) {
        const mtmd_input_chunk * c = mtmd_input_chunks_get(chunks, i);
        if (mtmd_input_chunk_get_type(c) == MTMD_INPUT_CHUNK_TYPE_IMAGE) {
            image_chunk = c;
            break;
        }
    }
    if (!image_chunk) {
        std::fprintf(stderr, "FAIL: no image chunk found\n");
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    const mtmd_image_tokens * image_tokens = mtmd_input_chunk_get_tokens_image(image_chunk);
    if (!image_tokens) {
        std::fprintf(stderr, "FAIL: image_tokens is null\n");
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    const size_t n_tokens = mtmd_image_tokens_get_n_tokens(image_tokens);
    const llama_pos n_pos = mtmd_input_chunk_get_n_pos(image_chunk);

    const size_t n_per_pair = (size_t) mtmd_image_tokens_get_nx(image_tokens) *
                              (size_t) mtmd_image_tokens_get_ny(image_tokens);
    std::fprintf(stderr, "INFO: nt=%u npairs=%u n_tokens=%zu nx=%zu ny=%zu n_pos=%lld n_per_pair=%zu\n",
                 nt, npairs, n_tokens,
                 mtmd_image_tokens_get_nx(image_tokens),
                 mtmd_image_tokens_get_ny(image_tokens),
                 (long long) n_pos, n_per_pair);

    if (n_tokens != n_per_pair * npairs) {
        std::fprintf(stderr, "FAIL: n_tokens=%zu != n_per_pair(%zu) * npairs(%u) = %zu\n",
                     n_tokens, n_per_pair, npairs, n_per_pair * npairs);
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    const llama_pos pos_0 = 100;
    bool saw_nonzero_t = false;
    bool saw_zero_t    = false;
    uint32_t prev_pair = UINT32_MAX;
    for (size_t i = 0; i < n_tokens; i++) {
        struct mtmd_decoder_pos pos = mtmd_image_tokens_get_decoder_pos(image_tokens, pos_0, i);
        const uint32_t expected_pair = (uint32_t)(i / n_per_pair);
        const uint32_t expected_x     = (uint32_t)(i % mtmd_image_tokens_get_nx(image_tokens));
        const uint32_t expected_y_within = (uint32_t)((i / mtmd_image_tokens_get_nx(image_tokens)) %
                                                       mtmd_image_tokens_get_ny(image_tokens));

        const uint32_t got_pair    = (uint32_t)(pos.t - pos_0);
        const uint32_t got_x       = (uint32_t)(pos.x - pos_0);
        const uint32_t got_y_within = (uint32_t)(pos.y - pos_0);

        if (got_pair != expected_pair) {
            std::fprintf(stderr, "FAIL: i=%zu pos.t=%u (pair=%u) expected pair=%u\n",
                         i, (uint32_t)pos.t, got_pair, expected_pair);
            mtmd_input_chunks_free(chunks);
            mtmd_bitmap_free(bitmap);
            mtmd_free(ctx);
            llama_model_free(text_model);
            return 1;
        }
        if (got_x != expected_x) {
            std::fprintf(stderr, "FAIL: i=%zu pos.x=%u (x=%u) expected x=%u\n",
                         i, (uint32_t)pos.x, got_x, expected_x);
            mtmd_input_chunks_free(chunks);
            mtmd_bitmap_free(bitmap);
            mtmd_free(ctx);
            llama_model_free(text_model);
            return 1;
        }
        if (got_y_within != expected_y_within) {
            std::fprintf(stderr, "FAIL: i=%zu pos.y=%u (y_within=%u) expected y_within=%u\n",
                         i, (uint32_t)pos.y, got_y_within, expected_y_within);
            mtmd_input_chunks_free(chunks);
            mtmd_bitmap_free(bitmap);
            mtmd_free(ctx);
            llama_model_free(text_model);
            return 1;
        }

        if (got_pair != prev_pair) {
            if (got_pair == 0) {
                saw_zero_t = true;
            } else {
                saw_nonzero_t = true;
            }
            prev_pair = got_pair;
        }
    }

    if (npairs > 1 && !saw_nonzero_t) {
        std::fprintf(stderr, "FAIL: expected non-zero T values for npairs=%u, but all tokens had pair=0\n", npairs);
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }
    if (npairs > 1 && !saw_zero_t) {
        std::fprintf(stderr, "FAIL: expected to see pair=0 tokens for npairs=%u, but none found\n", npairs);
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        mtmd_free(ctx);
        llama_model_free(text_model);
        return 1;
    }

    const size_t img_nx = mtmd_image_tokens_get_nx(image_tokens);
    const size_t img_ny = mtmd_image_tokens_get_ny(image_tokens);
    if (img_nx == 0 || img_ny == 0) {
        std::fprintf(stderr, "FAIL: invalid nx=%zu or ny=%zu\n", img_nx, img_ny);
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
