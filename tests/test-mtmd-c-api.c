#include <stdio.h>
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
