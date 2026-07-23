#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "verus/verus_clhash.h"

extern uint64_t precompReduction64(__m128i);

namespace {

constexpr size_t kKeyBytes = 8832;
constexpr size_t kKeyVectors = 552;
constexpr size_t kInputBytes = 64;
constexpr size_t kSteps = 32;

struct alignas(16) UInt4 {
    uint32_t x;
    uint32_t y;
    uint32_t z;
    uint32_t w;
};

static_assert(sizeof(UInt4) == 16, "Metal uint4 ABI mismatch");
static_assert(alignof(UInt4) == 16, "Metal uint4 alignment mismatch");

using Key = std::array<u128, kKeyVectors>;
using Input = std::array<unsigned char, kInputBytes>;
using Touched = std::array<uint32_t, kSteps>;

static_assert(sizeof(Key) == kKeyBytes, "Verus key ABI mismatch");
static_assert(sizeof(Input) == kInputBytes, "Verus input ABI mismatch");
static_assert(sizeof(Touched) == 128, "Verus touched-log ABI mismatch");

uint32_t xorshift32(uint32_t &state);

[[noreturn]] void fail(const std::string &message)
{
    std::fprintf(stderr, "FAIL: %s\n", message.c_str());
    std::exit(EXIT_FAILURE);
}

void generate_key(const unsigned char *seed, Key &key)
{
    unsigned char *output = reinterpret_cast<unsigned char *>(key.data());
    const unsigned char *input = seed;
    for (size_t offset = 0; offset < kKeyBytes; offset += 32) {
        haraka256(output + offset, input);
        input = output + offset;
    }
}

std::array<unsigned char, 16> rotate_left_one(
    const unsigned char *source)
{
    std::array<unsigned char, 16> result{};
    for (size_t i = 0; i < result.size(); ++i)
        result[i] = source[(i + 1) & 15];
    return result;
}

std::array<unsigned char, 16> rotated_repeated_u64(uint64_t value)
{
    std::array<unsigned char, 16> repeated{};
    std::memcpy(repeated.data(), &value, sizeof(value));
    std::memcpy(repeated.data() + sizeof(value), &value, sizeof(value));
    return rotate_left_one(repeated.data());
}

struct CanonicalVector {
    Input input{};
    Key key{};
};

CanonicalVector make_canonical_vector(uint32_t vector_id)
{
    CanonicalVector result;
    std::array<unsigned char, 15> nonce{};
    for (size_t i = 0; i < result.input.size(); ++i) {
        result.input[i] =
            static_cast<unsigned char>((i * 37 + vector_id * 53) & 0xff);
    }
    for (size_t i = 0; i < nonce.size(); ++i) {
        nonce[i] =
            static_cast<unsigned char>((i * 29 + vector_id * 71) & 0xff);
    }

    generate_key(result.input.data(), result.key);
    const auto fill = rotate_left_one(result.input.data());
    const unsigned char first_byte = result.input[0];
    std::memcpy(result.input.data() + 48, fill.data(), fill.size());
    result.input[47] = first_byte;
    std::memcpy(result.input.data() + 32, nonce.data(), nonce.size());
    return result;
}

Input finalized_input(Input input, uint64_t intermediate)
{
    const auto fill = rotated_repeated_u64(intermediate);
    std::memcpy(input.data() + 48, fill.data(), fill.size());
    input[47] = static_cast<unsigned char>(intermediate);
    return input;
}

std::array<unsigned char, 32> finalize_hash(
    Input input, uint64_t intermediate, const Key &mutated_key)
{
    input = finalized_input(input, intermediate);
    std::array<unsigned char, 32> output{};
    haraka512_keyed(
        output.data(), input.data(),
        mutated_key.data() + (intermediate & 511));
    return output;
}

std::string hex(const std::array<unsigned char, 32> &value)
{
    static constexpr char digits[] = "0123456789abcdef";
    std::string output(value.size() * 2, '0');
    for (size_t i = 0; i < value.size(); ++i) {
        output[i * 2] = digits[value[i] >> 4];
        output[i * 2 + 1] = digits[value[i] & 15];
    }
    return output;
}

std::array<uint32_t, 256> make_aes_table()
{
    static constexpr unsigned char sbox[256] = {
        0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
        0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
        0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
        0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
        0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
        0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
        0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
        0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
        0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
        0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
        0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
        0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
        0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
        0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
        0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
        0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
    };

    auto times_two = [](uint32_t value) {
        return ((value << 1) ^ (((value >> 7) & 1) * 0x11b)) & 0xff;
    };
    auto pack = [](uint32_t b0, uint32_t b1,
                   uint32_t b2, uint32_t b3) {
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
    };

    std::array<uint32_t, 256> table{};
    for (size_t i = 0; i < 256; ++i) {
        const uint32_t value = sbox[i];
        const uint32_t twice = times_two(value);
        const uint32_t thrice = twice ^ value;
        table[i] = pack(twice, value, value, thrice);
    }
    return table;
}

class MetalHarness {
public:
    explicit MetalHarness(const char *source_path)
    {
        device_ = MTLCreateSystemDefaultDevice();
        if (!device_)
            fail("Metal device unavailable");

        NSError *error = nil;
        NSString *path =
            [NSString stringWithUTF8String:source_path];
        NSString *source = [NSString stringWithContentsOfFile:path
                                                     encoding:NSUTF8StringEncoding
                                                        error:&error];
        if (!source)
            fail("cannot read Metal source: " +
                 std::string([[error localizedDescription] UTF8String]));

        MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
        options.languageVersion = MTLLanguageVersion3_0;
        id<MTLLibrary> library =
            [device_ newLibraryWithSource:source options:options error:&error];
        if (!library)
            fail("Metal source compilation failed:\n" +
                 std::string([[error localizedDescription] UTF8String]));

        prepare_ = make_pipeline(library, @"prepare_keys");
        restore_ = make_pipeline(library, @"restore_keys");
        primitive_ = make_pipeline(library, @"primitive_probe");
        clmul_benchmark_ = make_pipeline(library, @"clmul_benchmark");
        clhash_ = make_pipeline(library, @"verus_clhash_batch");
        queue_ = [device_ newCommandQueue];
        if (!queue_)
            fail("cannot create Metal command queue");

        const auto table = make_aes_table();
        tables_ = make_buffer(table.data(), sizeof(table));
    }

    const char *device_name() const
    {
        return [[device_ name] UTF8String];
    }

    id<MTLBuffer> make_buffer(size_t length)
    {
        if (length == 0 || length > device_.maxBufferLength)
            fail("Metal buffer size exceeds the device limit");
        id<MTLBuffer> buffer =
            [device_ newBufferWithLength:length
                                 options:MTLResourceStorageModeShared];
        if (!buffer)
            fail("Metal buffer allocation failed");
        return buffer;
    }

    id<MTLBuffer> make_buffer(const void *bytes, size_t length)
    {
        if (length == 0 || length > device_.maxBufferLength)
            fail("Metal buffer size exceeds the device limit");
        id<MTLBuffer> buffer =
            [device_ newBufferWithBytes:bytes
                                length:length
                               options:MTLResourceStorageModeShared];
        if (!buffer)
            fail("Metal buffer allocation failed");
        return buffer;
    }

    void run(
        id<MTLBuffer> pristine,
        id<MTLBuffer> keys,
        id<MTLBuffer> inputs,
        id<MTLBuffer> results,
        id<MTLBuffer> touched,
        id<MTLBuffer> case_masks,
        id<MTLBuffer> highwords,
        uint32_t count)
    {
        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        if (!command)
            fail("cannot create Metal command buffer");
        encode_prepare(command, pristine, keys, count);
        encode_hash(
            command, keys, inputs, results, touched, case_masks,
            highwords, count);
        finish(command);
    }

    void prepare_keys(
        id<MTLBuffer> pristine,
        id<MTLBuffer> keys,
        uint32_t count)
    {
        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        encode_prepare(command, pristine, keys, count);
        finish(command);
    }

    void run_reusable(
        id<MTLBuffer> pristine,
        id<MTLBuffer> keys,
        id<MTLBuffer> inputs,
        id<MTLBuffer> results,
        id<MTLBuffer> touched,
        id<MTLBuffer> case_masks,
        id<MTLBuffer> highwords,
        uint32_t count)
    {
        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        encode_hash(
            command, keys, inputs, results, touched, case_masks,
            highwords, count);

        id<MTLComputeCommandEncoder> encoder =
            [command computeCommandEncoder];
        [encoder setComputePipelineState:restore_];
        [encoder setBuffer:pristine offset:0 atIndex:0];
        [encoder setBuffer:keys offset:0 atIndex:1];
        [encoder setBuffer:touched offset:0 atIndex:2];
        [encoder setBytes:&count length:sizeof(count) atIndex:3];
        const NSUInteger width =
            std::min<NSUInteger>(64, restore_.maxTotalThreadsPerThreadgroup);
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
             threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
        [encoder endEncoding];
        finish(command);
    }

    void probe_primitives(
        const std::vector<UInt4> &left,
        const std::vector<UInt4> &right,
        std::vector<UInt4> &clmul_results,
        std::vector<UInt4> &mulhrs_results,
        std::vector<uint64_t> &reduction_results,
        std::vector<UInt4> &aes_results)
    {
        const uint32_t count = static_cast<uint32_t>(left.size());
        id<MTLBuffer> left_buffer =
            make_buffer(left.data(), left.size() * sizeof(UInt4));
        id<MTLBuffer> right_buffer =
            make_buffer(right.data(), right.size() * sizeof(UInt4));
        id<MTLBuffer> clmul_buffer =
            make_buffer(clmul_results.size() * sizeof(UInt4));
        id<MTLBuffer> mulhrs_buffer =
            make_buffer(mulhrs_results.size() * sizeof(UInt4));
        id<MTLBuffer> reduction_buffer =
            make_buffer(reduction_results.size() * sizeof(uint64_t));
        id<MTLBuffer> aes_buffer =
            make_buffer(aes_results.size() * sizeof(UInt4));

        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        id<MTLComputeCommandEncoder> encoder =
            [command computeCommandEncoder];
        [encoder setComputePipelineState:primitive_];
        [encoder setBuffer:left_buffer offset:0 atIndex:0];
        [encoder setBuffer:right_buffer offset:0 atIndex:1];
        [encoder setBuffer:clmul_buffer offset:0 atIndex:2];
        [encoder setBuffer:mulhrs_buffer offset:0 atIndex:3];
        [encoder setBuffer:reduction_buffer offset:0 atIndex:4];
        [encoder setBytes:&count length:sizeof(count) atIndex:5];
        [encoder setBuffer:tables_ offset:0 atIndex:6];
        [encoder setBuffer:aes_buffer offset:0 atIndex:7];
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
             threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
            fail("Metal primitive probe dispatch failed");

        std::memcpy(
            clmul_results.data(), clmul_buffer.contents,
            clmul_results.size() * sizeof(UInt4));
        std::memcpy(
            mulhrs_results.data(), mulhrs_buffer.contents,
            mulhrs_results.size() * sizeof(UInt4));
        std::memcpy(
            reduction_results.data(), reduction_buffer.contents,
            reduction_results.size() * sizeof(uint64_t));
        std::memcpy(
            aes_results.data(), aes_buffer.contents,
            aes_results.size() * sizeof(UInt4));
    }

    void benchmark_clmul(double duration, uint32_t count)
    {
        constexpr uint32_t iterations = 64;
        std::vector<UInt4> states(count);
        uint32_t seed = 0x243f6a88u;
        for (UInt4 &state : states) {
            state = {
                xorshift32(seed), xorshift32(seed),
                xorshift32(seed), xorshift32(seed)
            };
        }
        id<MTLBuffer> state_buffer =
            make_buffer(states.data(), states.size() * sizeof(UInt4));

        uint64_t operations = 0;
        const auto started = std::chrono::steady_clock::now();
        double elapsed = 0;
        do {
            id<MTLCommandBuffer> command = [queue_ commandBuffer];
            id<MTLComputeCommandEncoder> encoder =
                [command computeCommandEncoder];
            [encoder setComputePipelineState:clmul_benchmark_];
            [encoder setBuffer:state_buffer offset:0 atIndex:0];
            [encoder setBytes:&count length:sizeof(count) atIndex:1];
            [encoder setBytes:&iterations
                       length:sizeof(iterations) atIndex:2];
            const NSUInteger width = std::min<NSUInteger>(
                64, clmul_benchmark_.maxTotalThreadsPerThreadgroup);
            [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
            [encoder endEncoding];
            finish(command);
            operations += uint64_t(count) * iterations;
            elapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - started).count();
        } while (elapsed < duration);

        const UInt4 *result =
            static_cast<const UInt4 *>(state_buffer.contents);
        const uint32_t checksum =
            result[0].x ^ result[count - 1].w;
        if (checksum == 0)
            fail("unexpected zero carry-less multiply checksum");
        std::printf(
            "GPU carry-less multiply: %.3f Gop/s "
            "(%llu operations, %.3fs, batch %u, chain %u)\n",
            (double(operations) / elapsed) / 1000000000.0,
            static_cast<unsigned long long>(operations),
            elapsed, count, iterations);
    }

private:
    void encode_prepare(
        id<MTLCommandBuffer> command,
        id<MTLBuffer> pristine,
        id<MTLBuffer> keys,
        uint32_t count)
    {
        id<MTLComputeCommandEncoder> encoder =
            [command computeCommandEncoder];
        [encoder setComputePipelineState:prepare_];
        [encoder setBuffer:pristine offset:0 atIndex:0];
        [encoder setBuffer:keys offset:0 atIndex:1];
        [encoder setBytes:&count length:sizeof(count) atIndex:2];
        [encoder dispatchThreads:MTLSizeMake(kKeyVectors, count, 1)
             threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
        [encoder endEncoding];
    }

    void encode_hash(
        id<MTLCommandBuffer> command,
        id<MTLBuffer> keys,
        id<MTLBuffer> inputs,
        id<MTLBuffer> results,
        id<MTLBuffer> touched,
        id<MTLBuffer> case_masks,
        id<MTLBuffer> highwords,
        uint32_t count)
    {
        id<MTLComputeCommandEncoder> encoder =
            [command computeCommandEncoder];
        [encoder setComputePipelineState:clhash_];
        [encoder setBuffer:keys offset:0 atIndex:0];
        [encoder setBuffer:inputs offset:0 atIndex:1];
        [encoder setBuffer:results offset:0 atIndex:2];
        [encoder setBuffer:touched offset:0 atIndex:3];
        [encoder setBytes:&count length:sizeof(count) atIndex:4];
        [encoder setBuffer:tables_ offset:0 atIndex:5];
        [encoder setBuffer:case_masks offset:0 atIndex:6];
        [encoder setBuffer:highwords offset:0 atIndex:7];
        const NSUInteger width =
            std::min<NSUInteger>(64, clhash_.maxTotalThreadsPerThreadgroup);
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
             threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
        [encoder endEncoding];
    }

    void finish(id<MTLCommandBuffer> command)
    {
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) {
            NSError *error = command.error;
            fail("Metal dispatch failed: " +
                 std::string(error
                     ? [[error localizedDescription] UTF8String]
                     : "unknown command-buffer error"));
        }
    }

    id<MTLComputePipelineState> make_pipeline(
        id<MTLLibrary> library, NSString *name)
    {
        id<MTLFunction> function = [library newFunctionWithName:name];
        if (!function)
            fail("missing Metal function " +
                 std::string([name UTF8String]));
        NSError *error = nil;
        id<MTLComputePipelineState> pipeline =
            [device_ newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline)
            fail("cannot create Metal pipeline " +
                 std::string([name UTF8String]) + ": " +
                 std::string([[error localizedDescription] UTF8String]));
        return pipeline;
    }

    id<MTLDevice> device_;
    id<MTLCommandQueue> queue_;
    id<MTLComputePipelineState> prepare_;
    id<MTLComputePipelineState> restore_;
    id<MTLComputePipelineState> primitive_;
    id<MTLComputePipelineState> clmul_benchmark_;
    id<MTLComputePipelineState> clhash_;
    id<MTLBuffer> tables_;
};

void check_primitives(MetalHarness &metal)
{
    constexpr uint32_t count = 4096;
    std::vector<UInt4> left(count);
    std::vector<UInt4> right(count);
    uint32_t state = 0x9e3779b9u;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t *left_words = &left[i].x;
        uint32_t *right_words = &right[i].x;
        for (size_t word = 0; word < 4; ++word) {
            left_words[word] = xorshift32(state);
            right_words[word] = xorshift32(state);
        }
    }
    left[0] = {0x00008000u, 0x80000000u, 0x00008000u, 0x80000000u};
    right[0] = left[0];
    left[1] = {0, 0, 0, 0};
    left[2] = {0xffffffffu, 0xffffffffu, 0xffffffffu, 0xffffffffu};
    left[3] = {1, 0, 1, 0};
    left[4] = {0, 0x80000000u, 0, 0x80000000u};
    left[5] = {0xaaaaaaaau, 0xaaaaaaaau, 0x55555555u, 0x55555555u};
    left[6] = {0xffffffffu, 0xffffffffu, 0, 0x80000000u};

    std::vector<UInt4> clmul_actual(count);
    std::vector<UInt4> mulhrs_actual(count);
    std::vector<uint64_t> reduction_actual(count);
    std::vector<UInt4> aes_actual(count);
    metal.probe_primitives(
        left, right, clmul_actual, mulhrs_actual, reduction_actual,
        aes_actual);

    for (uint32_t i = 0; i < count; ++i) {
        __m128i left_value;
        __m128i right_value;
        std::memcpy(&left_value, &left[i], sizeof(left_value));
        std::memcpy(&right_value, &right[i], sizeof(right_value));
        const __m128i clmul_expected =
            _mm_clmulepi64_si128(left_value, left_value, 0x10);
        const __m128i mulhrs_expected =
            _mm_mulhrs_epi16(left_value, right_value);
        const __m128i aes_expected =
            _mm_aesenc_si128(left_value, right_value);
        if (std::memcmp(
                &clmul_expected, &clmul_actual[i], sizeof(UInt4)) != 0)
            fail("carry-less multiply primitive mismatch at lane " +
                 std::to_string(i));
        if (std::memcmp(
                &mulhrs_expected, &mulhrs_actual[i], sizeof(UInt4)) != 0)
            fail("mulhrs primitive mismatch at lane " +
                 std::to_string(i));
        const uint64_t reduction_expected =
            precompReduction64(left_value);
        if (reduction_expected != reduction_actual[i])
            fail("reduction primitive mismatch at lane " +
                 std::to_string(i));
        if (std::memcmp(
                &aes_expected, &aes_actual[i], sizeof(UInt4)) != 0)
            fail("AES round primitive mismatch at lane " +
                 std::to_string(i));
    }
}

struct Buffers {
    id<MTLBuffer> pristine;
    id<MTLBuffer> keys;
    id<MTLBuffer> inputs;
    id<MTLBuffer> results;
    id<MTLBuffer> touched;
    id<MTLBuffer> case_masks;
    id<MTLBuffer> highwords;
};

Buffers make_buffers(
    MetalHarness &metal, const Key &key,
    const std::vector<Input> &inputs)
{
    const size_t count = inputs.size();
    return {
        metal.make_buffer(key.data(), kKeyBytes),
        metal.make_buffer(count * kKeyBytes),
        metal.make_buffer(inputs.data(), count * sizeof(Input)),
        metal.make_buffer(count * sizeof(uint64_t)),
        metal.make_buffer(count * sizeof(Touched)),
        metal.make_buffer(count * sizeof(uint32_t)),
        metal.make_buffer(count * sizeof(uint32_t))
    };
}

uint64_t cpu_clhash(Key &key, const Input &input, Touched &touched)
{
    return verusclhashv2_2(
        key.data(), input.data(), 511, touched.data(),
        nullptr, nullptr, nullptr);
}

void check_canonical_vectors(MetalHarness &metal)
{
    static constexpr const char *expected_hashes[4] = {
        "2f5c21a15f092b8894c7d4dea1e308de6b9c82bd1c8dae3506438179e917fdad",
        "35e9dcba6b3b9496a904ac8806b5f07701486e489aca778414be678785479db7",
        "948b64e8f178e10a4874a4bc99ed16e755eb8b791c0bec485d81ed3929df9144",
        "2270ba2abe1cfea8509bc7b9bce389cb7b249accb5ab0dc43923eb2587120fd1"
    };

    for (uint32_t vector_id = 0; vector_id < 4; ++vector_id) {
        CanonicalVector vector = make_canonical_vector(vector_id);
        Key cpu_key = vector.key;
        Touched cpu_touched{};
        const uint64_t expected =
            cpu_clhash(cpu_key, vector.input, cpu_touched);
        std::vector<Input> inputs{vector.input};
        Buffers buffers = make_buffers(metal, vector.key, inputs);
        metal.run(
            buffers.pristine, buffers.keys, buffers.inputs,
            buffers.results, buffers.touched, buffers.case_masks,
            buffers.highwords, 1);

        const uint64_t actual =
            *static_cast<const uint64_t *>(buffers.results.contents);
        if (actual != expected) {
            const uint32_t *gpu_touched =
                static_cast<const uint32_t *>(buffers.touched.contents);
            size_t first_touched = kSteps;
            for (size_t i = 0; i < kSteps; ++i) {
                if (gpu_touched[i] != cpu_touched[i]) {
                    first_touched = i;
                    break;
                }
            }
            const unsigned char *gpu_key =
                static_cast<const unsigned char *>(buffers.keys.contents);
            const unsigned char *cpu_key_bytes =
                reinterpret_cast<const unsigned char *>(cpu_key.data());
            size_t first_key_byte = kKeyBytes;
            for (size_t i = 0; i < kKeyBytes; ++i) {
                if (gpu_key[i] != cpu_key_bytes[i]) {
                    first_key_byte = i;
                    break;
                }
            }
            std::fprintf(
                stderr,
                "debug vector %u: expected=%016llx actual=%016llx "
                "first_touched=%zu first_key_byte=%zu\n",
                vector_id,
                static_cast<unsigned long long>(expected),
                static_cast<unsigned long long>(actual),
                first_touched, first_key_byte);
            fail("canonical vector " + std::to_string(vector_id) +
                 " CLHash mismatch");
        }
        if (std::memcmp(
                buffers.touched.contents, cpu_touched.data(),
                sizeof(cpu_touched)) != 0)
            fail("canonical vector " + std::to_string(vector_id) +
                 " touched-index mismatch");
        if (std::memcmp(
                buffers.keys.contents, cpu_key.data(), kKeyBytes) != 0)
            fail("canonical vector " + std::to_string(vector_id) +
                 " mutated-key mismatch");

        Key gpu_key{};
        std::memcpy(gpu_key.data(), buffers.keys.contents, kKeyBytes);
        const Input final_input = finalized_input(vector.input, actual);
        const uint32_t expected_highword = haraka512_keyed_highword(
            final_input.data(), cpu_key.data() + (expected & 511));
        const uint32_t actual_highword =
            *static_cast<const uint32_t *>(buffers.highwords.contents);
        if (actual_highword != expected_highword)
            fail("canonical vector " + std::to_string(vector_id) +
                 " keyed-Haraka highword mismatch");
        const std::string actual_hash =
            hex(finalize_hash(vector.input, actual, gpu_key));
        if (actual_hash != expected_hashes[vector_id])
            fail("canonical vector " + std::to_string(vector_id) +
                 " final hash mismatch");
    }
}

uint32_t xorshift32(uint32_t &state)
{
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

void check_differential_batch(MetalHarness &metal)
{
    constexpr uint32_t count = 257;
    Input seed{};
    for (size_t i = 0; i < seed.size(); ++i)
        seed[i] = static_cast<unsigned char>((i * 43 + 19) & 0xff);
    Key pristine{};
    generate_key(seed.data(), pristine);

    std::vector<Input> inputs(count);
    uint32_t random_state = 0x6d2b79f5u;
    for (Input &input : inputs) {
        for (unsigned char &byte : input)
            byte = static_cast<unsigned char>(xorshift32(random_state));
    }

    std::vector<uint64_t> expected_results(count);
    std::vector<uint32_t> expected_highwords(count);
    std::vector<Touched> expected_touched(count);
    std::vector<Key> expected_keys(count);
    uint32_t collision_count = 0;
    for (uint32_t i = 0; i < count; ++i) {
        expected_keys[i] = pristine;
        expected_results[i] =
            cpu_clhash(expected_keys[i], inputs[i], expected_touched[i]);
        const Input final_input =
            finalized_input(inputs[i], expected_results[i]);
        expected_highwords[i] = haraka512_keyed_highword(
            final_input.data(),
            expected_keys[i].data() + (expected_results[i] & 511));
        for (uint32_t packed : expected_touched[i]) {
            if ((packed & 0xffffu) == (packed >> 16))
                ++collision_count;
        }
    }

    Buffers buffers = make_buffers(metal, pristine, inputs);
    metal.run(
        buffers.pristine, buffers.keys, buffers.inputs,
        buffers.results, buffers.touched, buffers.case_masks,
        buffers.highwords, count);

    if (std::memcmp(
            buffers.results.contents, expected_results.data(),
            expected_results.size() * sizeof(uint64_t)) != 0)
        fail("257-lane differential result mismatch");
    if (std::memcmp(
            buffers.touched.contents, expected_touched.data(),
            expected_touched.size() * sizeof(Touched)) != 0)
        fail("257-lane differential touched-index mismatch");
    if (std::memcmp(
            buffers.keys.contents, expected_keys.data(),
            expected_keys.size() * sizeof(Key)) != 0)
        fail("257-lane differential mutated-key mismatch");
    if (std::memcmp(
            buffers.highwords.contents, expected_highwords.data(),
            expected_highwords.size() * sizeof(uint32_t)) != 0)
        fail("257-lane differential keyed-Haraka highword mismatch");

    const uint32_t *case_masks =
        static_cast<const uint32_t *>(buffers.case_masks.contents);
    uint32_t aggregate_mask = 0;
    for (uint32_t i = 0; i < count; ++i)
        aggregate_mask |= case_masks[i];
    if (aggregate_mask != 0xffu)
        fail("differential batch did not cover all eight CLHash cases");
    if (collision_count == 0)
        fail("differential batch did not cover aliased key indices");

    const std::vector<Key> restored_keys(count, pristine);
    metal.prepare_keys(buffers.pristine, buffers.keys, count);
    for (uint32_t pass = 0; pass < 2; ++pass) {
        metal.run_reusable(
            buffers.pristine, buffers.keys, buffers.inputs,
            buffers.results, buffers.touched, buffers.case_masks,
            buffers.highwords, count);
        if (std::memcmp(
                buffers.results.contents, expected_results.data(),
                expected_results.size() * sizeof(uint64_t)) != 0 ||
            std::memcmp(
                buffers.highwords.contents, expected_highwords.data(),
                expected_highwords.size() * sizeof(uint32_t)) != 0)
            fail("reusable dispatch changed a verified result");
        if (std::memcmp(
                buffers.keys.contents, restored_keys.data(),
                restored_keys.size() * sizeof(Key)) != 0)
            fail("touched-key restoration did not recover pristine keys");
    }

    std::printf(
        "correctness: PASS (4 canonical + %u differential lanes, "
        "all cases, %u index collisions, reusable restore x2)\n",
        count, collision_count);
}

std::vector<Input> make_benchmark_inputs(
    uint32_t count, Input &seed)
{
    for (size_t i = 0; i < seed.size(); ++i)
        seed[i] = static_cast<unsigned char>((i * 37 + 17) & 0xff);
    std::array<unsigned char, 15> nonce{};
    for (size_t i = 0; i < nonce.size(); ++i)
        nonce[i] = static_cast<unsigned char>((i * 29 + 23) & 0xff);
    const auto fill = rotate_left_one(seed.data());
    const unsigned char first_byte = seed[0];

    std::vector<Input> inputs(count, seed);
    for (uint32_t counter = 0; counter < count; ++counter) {
        Input &input = inputs[counter];
        std::memcpy(input.data() + 32, nonce.data(), 11);
        std::memcpy(input.data() + 48, fill.data(), fill.size());
        input[47] = first_byte;
        std::memcpy(input.data() + 43, &counter, sizeof(counter));
    }
    return inputs;
}

void smoke_benchmark(
    MetalHarness &metal, double duration, uint32_t batch)
{
    Input seed{};
    std::vector<Input> inputs = make_benchmark_inputs(batch, seed);
    Key pristine{};
    generate_key(seed.data(), pristine);
    Buffers buffers = make_buffers(metal, pristine, inputs);

    metal.prepare_keys(buffers.pristine, buffers.keys, batch);
    metal.run_reusable(
        buffers.pristine, buffers.keys, buffers.inputs,
        buffers.results, buffers.touched, buffers.case_masks,
        buffers.highwords, batch);

    uint64_t hashes = 0;
    uint64_t checksum = 0;
    uint32_t nonce_base = batch;
    const auto started = std::chrono::steady_clock::now();
    double elapsed = 0;
    do {
        Input *device_inputs =
            static_cast<Input *>(buffers.inputs.contents);
        for (uint32_t i = 0; i < batch; ++i) {
            const uint32_t nonce = nonce_base + i;
            std::memcpy(
                device_inputs[i].data() + 43, &nonce, sizeof(nonce));
        }
        nonce_base += batch;
        metal.run_reusable(
            buffers.pristine, buffers.keys, buffers.inputs,
            buffers.results, buffers.touched, buffers.case_masks,
            buffers.highwords, batch);
        hashes += batch;
        const uint64_t *results =
            static_cast<const uint64_t *>(buffers.results.contents);
        const uint32_t *highwords =
            static_cast<const uint32_t *>(buffers.highwords.contents);
        checksum += results[0] ^ highwords[batch - 1];
        elapsed = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - started).count();
    } while (elapsed < duration);

    if (checksum == 0)
        fail("unexpected zero benchmark checksum");
    std::printf(
        "GPU Verus hot-path smoke: %.3f MH/s "
        "(%llu hashes, %.3fs, batch %u)\n",
        (double(hashes) / elapsed) / 1000000.0,
        static_cast<unsigned long long>(hashes), elapsed, batch);
    std::puts(
        "scope: CLHash + keyed-Haraka highword + touched-key restoration");
}

} // namespace

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 4) {
            std::fprintf(
                stderr, "usage: %s SHADER_PATH DURATION BATCH\n", argv[0]);
            return EXIT_FAILURE;
        }

        const double duration = std::strtod(argv[2], nullptr);
        const unsigned long parsed_batch = std::strtoul(argv[3], nullptr, 10);
        if (!(duration > 0 && duration <= 10) ||
            parsed_batch == 0 || parsed_batch > 8192)
            fail("invalid smoke benchmark arguments");

        load_constants();
        MetalHarness metal(argv[1]);
        std::printf("Metal device: %s\n", metal.device_name());
        const char *bench_only = std::getenv("BENCH_ONLY");
        if (!(bench_only && std::strcmp(bench_only, "1") == 0)) {
            check_primitives(metal);
            check_canonical_vectors(metal);
            check_differential_batch(metal);
        }
        metal.benchmark_clmul(
            std::min(2.0, duration),
            static_cast<uint32_t>(parsed_batch));
        smoke_benchmark(
            metal, duration, static_cast<uint32_t>(parsed_batch));
    }
    return EXIT_SUCCESS;
}
