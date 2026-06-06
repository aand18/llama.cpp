#include "mtmd-helper.h"

#include <cstdio>
#include <cstdlib>

static int failures = 0;

static void check(const char * name, int32_t got_h, int32_t got_w, int32_t exp_h, int32_t exp_w) {
    if (got_h != exp_h || got_w != exp_w) {
        std::fprintf(stderr,
                     "FAIL %s: got (%d, %d), expected (%d, %d)\n",
                     name, got_h, got_w, exp_h, exp_w);
        failures++;
    } else {
        std::fprintf(stderr, "OK   %s: (%d, %d)\n", name, got_h, got_w);
    }
}

static void test_smart_resize_100x100_default() {
    int32_t oh = 0, ow = 0;
    mtmd_helper_smart_resize(100, 100, 28, 784, 602112, &oh, &ow);
    check("100x100@28,min784,max602112", oh, ow, 112, 112);
}

static void test_smart_resize_1000x1000_downscale() {
    int32_t oh = 0, ow = 0;
    mtmd_helper_smart_resize(1000, 1000, 28, 784, 602112, &oh, &ow);
    check("1000x1000@28,min784,max602112", oh, ow, 756, 756);
}

static void test_smart_resize_small_input_too_low() {
    int32_t oh = 0, ow = 0;
    mtmd_helper_smart_resize(10, 10, 28, 784, 602112, &oh, &ow);
    check("10x10@28,min784,max602112", oh, ow, 28, 28);
}

static void test_smart_resize_upsample_to_min() {
    int32_t oh = 0, ow = 0;
    mtmd_helper_smart_resize(10, 10, 28, 1000, 602112, &oh, &ow);
    check("10x10@28,min1000,max602112", oh, ow, 56, 56);
}

static void test_smart_resize_1080p_downscale() {
    int32_t oh = 0, ow = 0;
    mtmd_helper_smart_resize(1080, 1920, 28, 100352, 602112, &oh, &ow);
    check("1080x1920@28,min100352,max602112", oh, ow, 560, 1008);
}

static void test_smart_resize_320x240_upscale_to_min() {
    int32_t oh = 0, ow = 0;
    mtmd_helper_smart_resize(240, 320, 28, 100352, 602112, &oh, &ow);
    check("240x320@28,min100352,max602112", oh, ow, 280, 392);
}

static void test_smart_resize_1920x1080_downscale() {
    int32_t oh = 0, ow = 0;
    mtmd_helper_smart_resize(1920, 1080, 28, 100352, 602112, &oh, &ow);
    check("1920x1080@28,min100352,max602112", oh, ow, 1008, 560);
}

static void test_smart_resize_tight_max() {
    int32_t oh = 0, ow = 0;
    mtmd_helper_smart_resize(200, 200, 28, 784, 784, &oh, &ow);
    check("200x200@28,min784,max784", oh, ow, 28, 28);
}

int main() {
    test_smart_resize_100x100_default();
    test_smart_resize_1000x1000_downscale();
    test_smart_resize_small_input_too_low();
    test_smart_resize_upsample_to_min();
    test_smart_resize_1080p_downscale();
    test_smart_resize_320x240_upscale_to_min();
    test_smart_resize_1920x1080_downscale();
    test_smart_resize_tight_max();
    if (failures > 0) {
        std::fprintf(stderr, "FAILED: %d test(s) failed\n", failures);
        return 1;
    }
    std::fprintf(stderr, "OK: all smart_resize tests passed\n");
    return 0;
}
