#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "mtmd.h"

int main(void) {
    printf("\n\nTesting libmtmd C API...\n");
    printf("--------\n\n");

    struct mtmd_context_params params = mtmd_context_params_default();
    printf("Default image marker: %s\n", params.image_marker);

    mtmd_input_chunks * chunks = mtmd_test_create_input_chunks();

    if (!chunks) {
        fprintf(stderr, "Failed to create input chunks\n");
        return 1;
    }

    size_t n_chunks = mtmd_input_chunks_size(chunks);
    printf("Number of chunks: %zu\n", n_chunks);
    assert(n_chunks > 0);

    for (size_t i = 0; i < n_chunks; i++) {
        const mtmd_input_chunk * chunk = mtmd_input_chunks_get(chunks, i);
        assert(chunk != NULL);
        enum mtmd_input_chunk_type type = mtmd_input_chunk_get_type(chunk);
        printf("Chunk %zu type: %d\n", i, type);

        if (type == MTMD_INPUT_CHUNK_TYPE_TEXT) {
            size_t n_tokens;
            const llama_token * tokens = mtmd_input_chunk_get_tokens_text(chunk, &n_tokens);
            printf("    Text chunk with %zu tokens\n", n_tokens);
            assert(tokens != NULL);
            assert(n_tokens > 0);
            for (size_t j = 0; j < n_tokens; j++) {
                assert(tokens[j] >= 0);
                printf("    > Token %zu: %d\n", j, tokens[j]);
            }

        } else if (type == MTMD_INPUT_CHUNK_TYPE_IMAGE) {
            const mtmd_image_tokens * image_tokens = mtmd_input_chunk_get_tokens_image(chunk);
            size_t n_tokens = mtmd_image_tokens_get_n_tokens(image_tokens);
            // get position of the last token, which should be (nx - 1, ny - 1)
            struct mtmd_decoder_pos pos = mtmd_image_tokens_get_decoder_pos(image_tokens, 0, n_tokens - 1);
            size_t nx = pos.x + 1;
            size_t ny = pos.y + 1;
            const char * id = mtmd_image_tokens_get_id(image_tokens);
            assert(n_tokens > 0);
            assert(nx > 0);
            assert(ny > 0);
            assert(id != NULL);
            printf("    Image chunk with %zu tokens\n", n_tokens);
            printf("    Image size: %zu x %zu\n", nx, ny);
            printf("    Image ID: %s\n", id);
        }
    }

    // Free the chunks
    mtmd_input_chunks_free(chunks);

    // Test that sequence bitmap API is wired up: a bitmap with nt=2 must
    // be reported as a sequence and have nt=2.
    int seq_res = mtmd_test_bitmap_is_seq();
    if (seq_res != 0) {
        fprintf(stderr, "mtmd_test_bitmap_is_seq failed (code=%d)\n", seq_res);
        return 1;
    }
    printf("Sequence bitmap API check: OK\n");

    // Test odd-nt round-up: a 3-frame input must produce a 4-frame bitmap
    // with the 4th frame being a duplicate of the 3rd. This pins down the
    // rounding behaviour and would catch a regression that reads past the
    // input buffer to fill the duplicate.
    {
        const uint32_t nx = 16, ny = 16;
        const uint32_t nt_in = 3;
        const size_t frame_size = (size_t) nx * ny * 3;
        const size_t data_size = nt_in * frame_size;
        unsigned char * data = malloc(data_size);
        if (!data) {
            fprintf(stderr, "malloc failed\n");
            return 1;
        }
        for (size_t i = 0; i < data_size; i++) {
            data[i] = (unsigned char) (i & 0xFF);
        }
        mtmd_bitmap * bitmap = mtmd_bitmap_init_from_seq(nx, ny, nt_in, data);
        free(data);
        if (!bitmap) {
            fprintf(stderr, "mtmd_bitmap_init_from_seq returned null for nt=%u\n", nt_in);
            return 1;
        }
        uint32_t nt_out = mtmd_bitmap_get_nt(bitmap);
        if (nt_out != nt_in + 1) {
            fprintf(stderr, "expected nt=%u (rounded up), got nt=%u\n", nt_in + 1, nt_out);
            mtmd_bitmap_free(bitmap);
            return 1;
        }
        const unsigned char * bdata = mtmd_bitmap_get_data(bitmap);
        if (!bdata) {
            fprintf(stderr, "mtmd_bitmap_get_data returned null\n");
            mtmd_bitmap_free(bitmap);
            return 1;
        }
        if (memcmp(bdata + 2 * frame_size, bdata + 3 * frame_size, frame_size) != 0) {
            fprintf(stderr, "frame 3 should be a duplicate of frame 2\n");
            mtmd_bitmap_free(bitmap);
            return 1;
        }
        mtmd_bitmap_free(bitmap);
        printf("Bitmap init from seq (odd nt) test: OK (nt_in=%u -> nt_out=%u, frame 3 == frame 2)\n", nt_in, nt_out);
    }

    // Smoke test: video extraction via ffmpeg subprocess.
    // Generate a small synthetic test video, then verify the extraction
    // helper produces frames with the expected dimensions and count.
    // Requires ffmpeg and ffprobe to be on PATH.
    {
        const char * test_video = "test_video_mtmd.mp4";
        char create_cmd[512];
        snprintf(create_cmd, sizeof(create_cmd),
            "ffmpeg -y -hide_banner -loglevel error -f lavfi -i testsrc=duration=1:size=320x240:rate=30 \"%s\"",
            test_video);
        int create_rc = system(create_cmd);
        if (create_rc != 0) {
            fprintf(stderr, "Failed to create test video (ffmpeg rc=%d). ffmpeg must be on PATH.\n", create_rc);
            return 1;
        }
        uint32_t vx = 0, vy = 0, vt = 0;
        int vres = mtmd_test_video_extract(test_video, 5.0f, 8, &vx, &vy, &vt);
        remove(test_video);
        if (vres != 0) {
            fprintf(stderr, "mtmd_test_video_extract failed (code=%d)\n", vres);
            return 1;
        }
        if (vx != 320 || vy != 240) {
            fprintf(stderr, "Expected 320x240, got %ux%u\n", vx, vy);
            return 1;
        }
        if (vt < 2) {
            fprintf(stderr, "Expected nt >= 2, got nt=%u\n", vt);
            return 1;
        }
        if (vt % 2 != 0) {
            fprintf(stderr, "Expected nt to be even (FRAME_FACTOR=2), got nt=%u\n", vt);
            return 1;
        }
        printf("Video extraction smoke test: OK (nx=%u, ny=%u, nt=%u, nt%%2=%u)\n", vx, vy, vt, vt % 2);
    }

    printf("\n\nDONE: test libmtmd C API...\n");

    return 0;
}
