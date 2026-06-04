#include "llama.h"
#include "mtmd.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <vector>

static int load_golden(const std::filesystem::path & path, std::vector<float> & out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        return 1;
    }
    f.seekg(0, std::ios::end);
    size_t sz = (size_t) f.tellg();
    f.seekg(0);
    out.resize(sz / sizeof(float));
    f.read(reinterpret_cast<char *>(out.data()), sz);
    return 0;
}

static std::filesystem::path find_repo_root() {
    std::filesystem::path cur = std::filesystem::current_path();
    while (!cur.empty()) {
        if (std::filesystem::exists(cur / "tests" / "CMakeLists.txt")) {
            return cur;
        }
        if (cur == cur.root_path()) {
            break;
        }
        cur = cur.parent_path();
    }
    return std::filesystem::current_path();
}

static int test_encode_nt(const char * model_path, const char * mmproj_path, uint32_t nt) {
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

    std::vector<float> actual;
    int enc_rc = mtmd_test_encode_bitmap(ctx, bitmap, actual);
    mtmd_bitmap_free(bitmap);
    mtmd_free(ctx);
    llama_model_free(text_model);
    if (enc_rc != 0) {
        std::fprintf(stderr, "FAIL: mtmd_test_encode_bitmap\n");
        return 1;
    }

    std::filesystem::path repo = find_repo_root();
    std::filesystem::path testdata = repo / "tests" / "testdata";
    std::filesystem::create_directories(testdata);
    std::filesystem::path golden = testdata / (std::string("encoder-nt") + std::to_string(nt) + "-qwen2vl.bin");

    std::vector<float> saved;
    if (load_golden(golden, saved) != 0) {
        std::fprintf(stderr, "INFO: no golden file at %s; recording current output as golden\n", golden.string().c_str());
        std::ofstream f(golden, std::ios::binary);
        if (!f) {
            std::fprintf(stderr, "FAIL: cannot write golden file at %s\n", golden.string().c_str());
            return 1;
        }
        f.write(reinterpret_cast<const char *>(actual.data()), actual.size() * sizeof(float));
        return 0;
    }

    if (actual.size() != saved.size()) {
        std::fprintf(stderr, "FAIL: size mismatch: actual=%zu golden=%zu\n", actual.size(), saved.size());
        return 1;
    }

    for (size_t i = 0; i < actual.size(); i++) {
        if (actual[i] != saved[i]) {
            std::fprintf(stderr, "FAIL: mismatch at index %zu: actual=%f golden=%f\n", i, actual[i], saved[i]);
            return 1;
        }
    }

    std::fprintf(stderr, "OK: encoder-nt=%u matches golden (%zu floats)\n", nt, actual.size());
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

    int rc = test_encode_nt(model, mmproj, nt);

    llama_backend_free();
    return rc;
}
