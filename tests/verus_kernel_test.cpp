#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "verus/verus_clhash.h"

namespace {

constexpr size_t kKeyBytes = 8832;
constexpr size_t kKeyVectors = kKeyBytes / sizeof(u128);
using KernelFunction = uint64_t (*)(void *, const unsigned char *, uint64_t,
                                    uint32_t *, uint32_t *, u128 *, u128 *);
#ifdef ARM
using DualKernelFunction = void (*)(
    void *, const unsigned char *, uint32_t *,
    void *, const unsigned char *, uint32_t *, uint64_t *);
#endif

#ifdef VERUS_HAVE_BASELINE
extern "C" uint64_t baseline_verusclhashv2_2(
    void *, const unsigned char *, uint64_t, uint32_t *, uint32_t *, u128 *, u128 *);
#ifdef ARM
extern "C" void baseline_verusclhashv2_2_dual(
    void *, const unsigned char *, uint32_t *,
    void *, const unsigned char *, uint32_t *, uint64_t *);
#endif
#endif

#if defined(ARM) && defined(VERUS_TESTING)
extern "C" __m128i verus_test_mulhrs_epi16(__m128i, __m128i);

void test_native_mulhrs()
{
    uint32_t state = 0x6d2b79f5;
    for (uint32_t round = 0; round < 10000; ++round)
    {
        alignas(16) int16_t left[8];
        alignas(16) int16_t right[8];
        for (int lane = 0; lane < 8; ++lane)
        {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            left[lane] = static_cast<int16_t>(state);
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            right[lane] = static_cast<int16_t>(state);
        }
        left[round & 7] = -32768;
        right[round & 7] = -32768;

        const __m128i a = _mm_load_si128(
            reinterpret_cast<const __m128i *>(left));
        const __m128i b = _mm_load_si128(
            reinterpret_cast<const __m128i *>(right));
        const __m128i expected = _mm_mulhrs_epi16(a, b);
        const __m128i actual = verus_test_mulhrs_epi16(a, b);
        alignas(16) unsigned char expected_bytes[16];
        alignas(16) unsigned char actual_bytes[16];
        _mm_store_si128(
            reinterpret_cast<__m128i *>(expected_bytes), expected);
        _mm_store_si128(
            reinterpret_cast<__m128i *>(actual_bytes), actual);
        if (std::memcmp(expected_bytes, actual_bytes, 16) != 0)
        {
            std::fprintf(
                stderr, "native mulhrs mismatch in round %u\n", round);
            std::exit(EXIT_FAILURE);
        }
    }
}
#endif

u128 rotate_bytes_left_one(u128 value)
{
#ifdef ARM
    const uint8x16_t bytes = vreinterpretq_u8_m128i(value);
    return vreinterpretq_m128i_u8(vextq_u8(bytes, bytes, 1));
#else
    const u128 shuffle = _mm_setr_epi8(
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0);
    return _mm_shuffle_epi8(value, shuffle);
#endif
}

u128 rotate_repeated_u64(uint64_t value)
{
#ifdef ARM
    const uint8x16_t bytes =
        vreinterpretq_u8_u64(vdupq_n_u64(value));
    return vreinterpretq_m128i_u8(vextq_u8(bytes, bytes, 1));
#else
    const u128 shuffle = _mm_setr_epi8(
        1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0);
    return _mm_shuffle_epi8(_mm_set1_epi64x(value), shuffle);
#endif
}

void generate_key(const unsigned char *seed, u128 *key)
{
    unsigned char *output = reinterpret_cast<unsigned char *>(key);
    const unsigned char *input = seed;

    for (size_t offset = 0; offset < kKeyBytes; offset += 32)
    {
        haraka256(output + offset, input);
        input = output + offset;
    }
}

void restore_saved_key(const uint32_t *first_indices,
                       const uint32_t *second_indices,
                       u128 *key,
                       const u128 *first_values,
                       const u128 *second_values)
{
    for (int i = 31; i >= 0; --i)
    {
        key[second_indices[i]] = second_values[i];
        key[first_indices[i]] = first_values[i];
    }
}

using TouchedLog = std::array<uint32_t, 32>;

void restore_packed_key(const uint32_t *touched, u128 *key, const u128 *pristine)
{
    for (int i = 0; i < 32; ++i)
    {
        const uint32_t packed = touched[i];
        key[packed & 0xffff] = pristine[packed & 0xffff];
        key[packed >> 16] = pristine[packed >> 16];
    }
}

std::array<unsigned char, 32> hash_vector(uint32_t vector_id)
{
    alignas(32) std::array<unsigned char, 64> buffer{};
    alignas(32) std::array<u128, kKeyVectors + 64> key{};
    alignas(32) std::array<u128, kKeyVectors> pristine_key{};
    alignas(32) std::array<u128, 32> first_values{};
    alignas(32) std::array<u128, 32> second_values{};
    TouchedLog touched{};
    std::array<uint32_t, 32> second_indices{};
    std::array<unsigned char, 15> nonce{};
    std::array<unsigned char, 32> hash{};

    for (size_t i = 0; i < buffer.size(); ++i)
        buffer[i] = static_cast<unsigned char>((i * 37 + vector_id * 53) & 0xff);
    for (size_t i = 0; i < nonce.size(); ++i)
        nonce[i] = static_cast<unsigned char>((i * 29 + vector_id * 71) & 0xff);

    generate_key(buffer.data(), key.data());
    std::memcpy(pristine_key.data(), key.data(), kKeyBytes);

    const u128 fill = rotate_bytes_left_one(_mm_load_si128(
        reinterpret_cast<const u128 *>(buffer.data())));
    const unsigned char first_byte = buffer[0];
    _mm_store_si128(reinterpret_cast<u128 *>(buffer.data() + 48), fill);
    buffer[47] = first_byte;
    std::memcpy(buffer.data() + 32, nonce.data(), nonce.size());

    uint64_t intermediate = verusclhashv2_2(
        key.data(),
        buffer.data(),
        511,
        reinterpret_cast<uint32_t *>(touched.data()),
#ifdef ARM
        nullptr,
        nullptr,
        nullptr);
#else
        second_indices.data(),
        first_values.data(),
        second_values.data());
#endif

    const u128 final_fill = rotate_repeated_u64(intermediate);
    _mm_store_si128(reinterpret_cast<u128 *>(buffer.data() + 48), final_fill);
    buffer[47] = static_cast<unsigned char>(intermediate);
    const u128 *final_key = key.data() + (intermediate & 511);
    const uint32_t highword =
        haraka512_keyed_highword(buffer.data(), final_key);
    haraka512_keyed(hash.data(), buffer.data(), final_key);
    uint32_t full_highword;
    std::memcpy(&full_highword, hash.data() + 28, sizeof(full_highword));
    if (highword != full_highword)
    {
        std::fprintf(stderr, "vector %u high-word filter mismatch\n", vector_id);
        std::exit(EXIT_FAILURE);
    }

#ifdef ARM
    restore_packed_key(touched.data(), key.data(), pristine_key.data());
#else
    restore_saved_key(
        touched.data(), second_indices.data(), key.data(),
        first_values.data(), second_values.data());
#endif
    if (std::memcmp(pristine_key.data(), key.data(), kKeyBytes) != 0)
    {
        std::fprintf(stderr, "vector %u did not restore the Verus key\n", vector_id);
        std::exit(EXIT_FAILURE);
    }
    return hash;
}

#ifdef ARM
void test_dual_kernel()
{
    struct LaneFixture {
        alignas(32) std::array<unsigned char, 64> buffer{};
        alignas(32) std::array<u128, kKeyVectors + 64> dual_key{};
        alignas(32) std::array<u128, kKeyVectors + 64> scalar_key{};
        TouchedLog dual_touched{};
        TouchedLog scalar_touched{};
    };

    std::array<LaneFixture, 2> fixtures{};
    std::array<std::array<u128, kKeyVectors>, 2> pristine_keys{};
    std::array<unsigned char, 64> seed{};
    for (size_t i = 0; i < seed.size(); ++i)
        seed[i] = static_cast<unsigned char>((i * 43 + 19) & 0xff);
    for (size_t lane = 0; lane < fixtures.size(); ++lane)
    {
        seed[0] = static_cast<unsigned char>(lane * 71);
        generate_key(seed.data(), pristine_keys[lane].data());
    }

    for (uint32_t group = 0; group < 128; ++group)
    {
        std::array<uint64_t, 2> dual_results{};
        std::array<uint64_t, 2> scalar_results{};

        for (size_t lane = 0; lane < fixtures.size(); ++lane)
        {
            LaneFixture &fixture = fixtures[lane];
            std::memcpy(
                fixture.dual_key.data(), pristine_keys[lane].data(), kKeyBytes);
            std::memcpy(
                fixture.scalar_key.data(), pristine_keys[lane].data(), kKeyBytes);
            for (size_t i = 0; i < fixture.buffer.size(); ++i)
            {
                fixture.buffer[i] = static_cast<unsigned char>(
                    (i * 37 + lane * 83 + group * 29) & 0xff);
            }

        }

        verusclhashv2_2_dual(
            fixtures[0].dual_key.data(), fixtures[0].buffer.data(),
            fixtures[0].dual_touched.data(),
            fixtures[1].dual_key.data(), fixtures[1].buffer.data(),
            fixtures[1].dual_touched.data(), dual_results.data());

        for (size_t lane = 0; lane < fixtures.size(); ++lane)
        {
            LaneFixture &fixture = fixtures[lane];
            scalar_results[lane] = verusclhashv2_2(
                fixture.scalar_key.data(),
                fixture.buffer.data(),
                511,
                reinterpret_cast<uint32_t *>(
                    fixture.scalar_touched.data()),
                nullptr,
                nullptr,
                nullptr);
            if (dual_results[lane] != scalar_results[lane])
            {
                std::fprintf(
                    stderr, "dual CLHash mismatch in group %u lane %zu\n",
                    group, lane);
                std::exit(EXIT_FAILURE);
            }

            std::array<unsigned char, 32> dual_hash{};
            std::array<unsigned char, 32> scalar_hash{};
            haraka512_keyed(
                dual_hash.data(),
                fixture.buffer.data(),
                fixture.dual_key.data() + (dual_results[lane] & 511));
            haraka512_keyed(
                scalar_hash.data(),
                fixture.buffer.data(),
                fixture.scalar_key.data() + (scalar_results[lane] & 511));
            if (dual_hash != scalar_hash)
            {
                std::fprintf(
                    stderr, "dual final-hash mismatch in group %u lane %zu\n",
                    group, lane);
                std::exit(EXIT_FAILURE);
            }

            restore_packed_key(
                fixture.dual_touched.data(), fixture.dual_key.data(),
                pristine_keys[lane].data());
            restore_packed_key(
                fixture.scalar_touched.data(), fixture.scalar_key.data(),
                pristine_keys[lane].data());
            if (std::memcmp(
                    fixture.dual_key.data(), pristine_keys[lane].data(),
                    kKeyBytes) != 0 ||
                std::memcmp(
                    fixture.scalar_key.data(), pristine_keys[lane].data(),
                    kKeyBytes) != 0)
            {
                std::fprintf(
                    stderr, "dual key restore mismatch in group %u lane %zu\n",
                    group, lane);
                std::exit(EXIT_FAILURE);
            }
        }
    }
}

#ifdef VERUS_HAVE_BASELINE
void differential_failure(
    const char *what, uint32_t group, uint32_t repeat, size_t lane)
{
    std::fprintf(
        stderr,
        "baseline/candidate %s mismatch in group %u repeat %u lane %zu\n",
        what, group, repeat, lane);
    std::exit(EXIT_FAILURE);
}

void test_dual_baseline_state()
{
    constexpr uint32_t kGroups = 2048;
    constexpr uint32_t kRepeats = 2;

    struct LaneFixture {
        alignas(32) std::array<unsigned char, 64> buffer{};
        alignas(32) std::array<u128, kKeyVectors + 64> pristine_key{};
        alignas(32) std::array<u128, kKeyVectors + 64> baseline_key{};
        alignas(32) std::array<u128, kKeyVectors + 64> candidate_key{};
        TouchedLog baseline_touched{};
        TouchedLog candidate_touched{};
    };

    std::array<LaneFixture, 2> fixtures{};
    uint32_t random_state = 0x243f6a88u;
    uint64_t alias_count = 0;

    const auto random32 = [&random_state]() {
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    };

    for (uint32_t group = 0; group < kGroups; ++group)
    {
        for (size_t lane = 0; lane < fixtures.size(); ++lane)
        {
            LaneFixture &fixture = fixtures[lane];
            std::array<unsigned char, 64> seed{};
            for (unsigned char &byte : seed)
                byte = static_cast<unsigned char>(random32());
            generate_key(seed.data(), fixture.pristine_key.data());
            std::memcpy(
                fixture.baseline_key.data(), fixture.pristine_key.data(),
                kKeyBytes);
            std::memcpy(
                fixture.candidate_key.data(), fixture.pristine_key.data(),
                kKeyBytes);
        }

        for (uint32_t repeat = 0; repeat < kRepeats; ++repeat)
        {
            for (LaneFixture &fixture : fixtures)
            {
                for (unsigned char &byte : fixture.buffer)
                    byte = static_cast<unsigned char>(random32());
                fixture.baseline_touched.fill(0xa5a5a5a5u);
                fixture.candidate_touched.fill(0x5a5a5a5au);
            }

            std::array<uint64_t, 2> baseline_results{};
            std::array<uint64_t, 2> candidate_results{};
            baseline_verusclhashv2_2_dual(
                fixtures[0].baseline_key.data(), fixtures[0].buffer.data(),
                fixtures[0].baseline_touched.data(),
                fixtures[1].baseline_key.data(), fixtures[1].buffer.data(),
                fixtures[1].baseline_touched.data(), baseline_results.data());
            verusclhashv2_2_dual(
                fixtures[0].candidate_key.data(), fixtures[0].buffer.data(),
                fixtures[0].candidate_touched.data(),
                fixtures[1].candidate_key.data(), fixtures[1].buffer.data(),
                fixtures[1].candidate_touched.data(), candidate_results.data());

            for (size_t lane = 0; lane < fixtures.size(); ++lane)
            {
                LaneFixture &fixture = fixtures[lane];
                if (baseline_results[lane] != candidate_results[lane])
                    differential_failure("intermediate", group, repeat, lane);
                if (fixture.baseline_touched != fixture.candidate_touched)
                    differential_failure("touched log", group, repeat, lane);
                if (std::memcmp(
                        fixture.baseline_key.data(),
                        fixture.candidate_key.data(), kKeyBytes) != 0)
                    differential_failure("mutated key", group, repeat, lane);

                for (uint32_t packed : fixture.candidate_touched)
                {
                    if ((packed & 0xffffu) == (packed >> 16))
                        ++alias_count;
                }

                std::array<unsigned char, 64> baseline_final =
                    fixture.buffer;
                std::array<unsigned char, 64> candidate_final =
                    fixture.buffer;
                const u128 baseline_fill =
                    rotate_repeated_u64(baseline_results[lane]);
                const u128 candidate_fill =
                    rotate_repeated_u64(candidate_results[lane]);
                _mm_storeu_si128(
                    reinterpret_cast<u128 *>(baseline_final.data() + 48),
                    baseline_fill);
                _mm_storeu_si128(
                    reinterpret_cast<u128 *>(candidate_final.data() + 48),
                    candidate_fill);
                baseline_final[47] =
                    static_cast<unsigned char>(baseline_results[lane]);
                candidate_final[47] =
                    static_cast<unsigned char>(candidate_results[lane]);

                std::array<unsigned char, 32> baseline_hash{};
                std::array<unsigned char, 32> candidate_hash{};
                haraka512_keyed(
                    baseline_hash.data(), baseline_final.data(),
                    fixture.baseline_key.data() +
                        (baseline_results[lane] & 511));
                haraka512_keyed(
                    candidate_hash.data(), candidate_final.data(),
                    fixture.candidate_key.data() +
                        (candidate_results[lane] & 511));
                if (baseline_hash != candidate_hash)
                    differential_failure("final hash", group, repeat, lane);

                restore_packed_key(
                    fixture.baseline_touched.data(),
                    fixture.baseline_key.data(),
                    fixture.pristine_key.data());
                restore_packed_key(
                    fixture.candidate_touched.data(),
                    fixture.candidate_key.data(),
                    fixture.pristine_key.data());
                if (std::memcmp(
                        fixture.baseline_key.data(),
                        fixture.pristine_key.data(), kKeyBytes) != 0)
                    differential_failure(
                        "baseline restore", group, repeat, lane);
                if (std::memcmp(
                        fixture.candidate_key.data(),
                        fixture.pristine_key.data(), kKeyBytes) != 0)
                    differential_failure(
                        "candidate restore", group, repeat, lane);
            }
        }
    }

    if (alias_count == 0)
    {
        std::fprintf(
            stderr,
            "baseline/candidate state differential did not cover key aliases\n");
        std::exit(EXIT_FAILURE);
    }
    std::printf(
        "baseline/candidate dual state: PASS "
        "(%u calls, %llu aliased key-index pairs)\n",
        kGroups * kRepeats,
        static_cast<unsigned long long>(alias_count));
}
#endif

#endif

double benchmark_kernel(uint32_t iterations,
                        KernelFunction kernel = verusclhashv2_2,
#ifdef ARM
                        bool packed_restore = true)
#else
                        bool packed_restore = false)
#endif
{
    alignas(32) std::array<unsigned char, 64> buffer{};
    alignas(32) std::array<u128, kKeyVectors + 64> key{};
    alignas(32) std::array<u128, kKeyVectors> pristine_key{};
    alignas(32) std::array<u128, 32> first_values{};
    alignas(32) std::array<u128, 32> second_values{};
    TouchedLog first_indices{};
    std::array<uint32_t, 32> second_indices{};
    std::array<unsigned char, 15> nonce{};
    std::array<unsigned char, 32> hash{};
    uint64_t checksum = 0;

    for (size_t i = 0; i < buffer.size(); ++i)
        buffer[i] = static_cast<unsigned char>((i * 37 + 17) & 0xff);
    for (size_t i = 0; i < nonce.size(); ++i)
        nonce[i] = static_cast<unsigned char>((i * 29 + 23) & 0xff);
    generate_key(buffer.data(), key.data());
    std::memcpy(pristine_key.data(), key.data(), kKeyBytes);

    const u128 fill = rotate_bytes_left_one(_mm_load_si128(
        reinterpret_cast<const u128 *>(buffer.data())));
    const unsigned char first_byte = buffer[0];
    std::memcpy(buffer.data() + 32, nonce.data(), 11);

    const auto started = std::chrono::steady_clock::now();
    for (uint32_t counter = 0; counter < iterations; ++counter)
    {
        _mm_store_si128(reinterpret_cast<u128 *>(buffer.data() + 48), fill);
        buffer[47] = first_byte;
        std::memcpy(buffer.data() + 43, &counter, sizeof(counter));

        uint64_t intermediate = kernel(
            key.data(),
            buffer.data(),
            511,
            reinterpret_cast<uint32_t *>(first_indices.data()),
            second_indices.data(),
            first_values.data(),
            second_values.data());

        const u128 final_fill = rotate_repeated_u64(intermediate);
        _mm_store_si128(reinterpret_cast<u128 *>(buffer.data() + 48), final_fill);
        buffer[47] = static_cast<unsigned char>(intermediate);
        const uint32_t highword = haraka512_keyed_highword(
            buffer.data(), key.data() + (intermediate & 511));
#ifdef ARM
        if (packed_restore)
            restore_packed_key(
                first_indices.data(), key.data(), pristine_key.data());
        else
#endif
            restore_saved_key(
                reinterpret_cast<uint32_t *>(first_indices.data()),
                second_indices.data(), key.data(),
                first_values.data(), second_values.data());
        checksum += highword;
    }
    const auto stopped = std::chrono::steady_clock::now();

    if (checksum == 0)
        std::fprintf(stderr, "unexpected zero benchmark checksum\n");
    return std::chrono::duration<double>(stopped - started).count();
}

#ifdef ARM
struct DualBenchmarkResult {
    double seconds;
    uint64_t checksum;
};

template <DualKernelFunction Kernel>
DualBenchmarkResult benchmark_dual_kernel(uint32_t iterations)
{
    struct BenchLane {
        alignas(32) std::array<unsigned char, 64> buffer{};
        alignas(32) std::array<u128, kKeyVectors + 64> key{};
        TouchedLog touched{};
    };

    std::array<BenchLane, 2> fixture{};
    alignas(32) std::array<u128, kKeyVectors> pristine_key{};
    std::array<unsigned char, 15> nonce{};
    uint64_t checksum = 0;

    for (size_t i = 0; i < fixture[0].buffer.size(); ++i)
        fixture[0].buffer[i] =
            static_cast<unsigned char>((i * 37 + 17) & 0xff);
    for (size_t i = 0; i < nonce.size(); ++i)
        nonce[i] = static_cast<unsigned char>((i * 29 + 23) & 0xff);
    generate_key(fixture[0].buffer.data(), pristine_key.data());

    for (size_t lane = 0; lane < fixture.size(); ++lane)
    {
        fixture[lane].buffer = fixture[0].buffer;
        std::memcpy(
            fixture[lane].key.data(), pristine_key.data(), kKeyBytes);
        std::memcpy(fixture[lane].buffer.data() + 32, nonce.data(), 11);
    }

    const u128 fill = rotate_bytes_left_one(_mm_load_si128(
        reinterpret_cast<const u128 *>(fixture[0].buffer.data())));
    const unsigned char first_byte = fixture[0].buffer[0];

    const auto started = std::chrono::steady_clock::now();
    uint32_t counter = 0;
    for (; counter + 1 < iterations; counter += 2)
    {
        for (size_t lane = 0; lane < fixture.size(); ++lane)
        {
            _mm_store_si128(
                reinterpret_cast<u128 *>(fixture[lane].buffer.data() + 48),
                fill);
            fixture[lane].buffer[47] = first_byte;
            const uint32_t lane_counter =
                counter + static_cast<uint32_t>(lane);
            std::memcpy(
                fixture[lane].buffer.data() + 43,
                &lane_counter,
                sizeof(lane_counter));
        }

        std::array<uint64_t, 2> intermediate{};
        Kernel(
            fixture[0].key.data(), fixture[0].buffer.data(),
            fixture[0].touched.data(),
            fixture[1].key.data(), fixture[1].buffer.data(),
            fixture[1].touched.data(), intermediate.data());
        for (size_t lane = 0; lane < fixture.size(); ++lane)
        {
            const u128 final_fill =
                rotate_repeated_u64(intermediate[lane]);
            _mm_store_si128(
                reinterpret_cast<u128 *>(fixture[lane].buffer.data() + 48),
                final_fill);
            fixture[lane].buffer[47] =
                static_cast<unsigned char>(intermediate[lane]);
            checksum += haraka512_keyed_highword(
                fixture[lane].buffer.data(),
                fixture[lane].key.data() + (intermediate[lane] & 511));
            restore_packed_key(
                fixture[lane].touched.data(),
                fixture[lane].key.data(),
                pristine_key.data());
        }
    }
    const auto stopped = std::chrono::steady_clock::now();

    if (counter != iterations)
    {
        std::fprintf(stderr, "dual benchmark iteration count must be even\n");
        std::exit(EXIT_FAILURE);
    }
    if (checksum == 0)
        std::fprintf(stderr, "unexpected zero dual benchmark checksum\n");
    return {
        std::chrono::duration<double>(stopped - started).count(),
        checksum,
    };
}
#endif

void print_hex(const std::array<unsigned char, 32> &value)
{
    for (unsigned char byte : value)
        std::printf("%02x", byte);
}

} // namespace

int main(int argc, char **argv)
{
    load_constants();

#ifdef VERUS_HAVE_BASELINE
#ifdef ARM
    if (argc >= 2 && std::strcmp(argv[1], "--differential-dual") == 0)
    {
        if (argc != 2)
        {
            std::fprintf(
                stderr, "--differential-dual does not accept arguments\n");
            return EXIT_FAILURE;
        }
        test_dual_baseline_state();
        return EXIT_SUCCESS;
    }

    if (argc >= 2 && std::strcmp(argv[1], "--compare-dual") == 0)
    {
        const uint32_t iterations = argc == 3
            ? static_cast<uint32_t>(std::strtoul(argv[2], nullptr, 10))
            : 1000000;
        if (iterations == 0 || (iterations & 1) != 0)
        {
            std::fprintf(
                stderr,
                "dual comparison iteration count must be positive and even\n");
            return EXIT_FAILURE;
        }

        const uint32_t warmup_iterations =
            iterations < 200000 ? iterations : 200000;
        const auto baseline_warmup =
            benchmark_dual_kernel<baseline_verusclhashv2_2_dual>(
                warmup_iterations);
        const auto candidate_warmup =
            benchmark_dual_kernel<verusclhashv2_2_dual>(warmup_iterations);
        if (baseline_warmup.checksum != candidate_warmup.checksum)
        {
            std::fprintf(stderr, "dual warmup checksum mismatch\n");
            return EXIT_FAILURE;
        }

        double baseline_seconds = 0;
        double candidate_seconds = 0;
        for (unsigned int round = 0; round < 4; ++round)
        {
            DualBenchmarkResult baseline;
            DualBenchmarkResult candidate;
            if ((round & 1) == 0)
            {
                baseline =
                    benchmark_dual_kernel<baseline_verusclhashv2_2_dual>(
                        iterations);
                candidate = benchmark_dual_kernel<verusclhashv2_2_dual>(
                    iterations);
            }
            else
            {
                candidate = benchmark_dual_kernel<verusclhashv2_2_dual>(
                    iterations);
                baseline =
                    benchmark_dual_kernel<baseline_verusclhashv2_2_dual>(
                        iterations);
            }
            if (baseline.checksum != candidate.checksum)
            {
                std::fprintf(
                    stderr, "dual checksum mismatch in round %u\n", round + 1);
                return EXIT_FAILURE;
            }
            baseline_seconds += baseline.seconds;
            candidate_seconds += candidate.seconds;
            std::printf(
                "round %u: baseline %.6fs, candidate %.6fs, delta %+.3f%%\n",
                round + 1,
                baseline.seconds,
                candidate.seconds,
                ((baseline.seconds / candidate.seconds) - 1.0) * 100.0);
        }
        std::printf(
            "aggregate: baseline %.6fs, candidate %.6fs, delta %+.3f%%\n",
            baseline_seconds,
            candidate_seconds,
            ((baseline_seconds / candidate_seconds) - 1.0) * 100.0);
        return EXIT_SUCCESS;
    }
#endif

    if (argc >= 2 && std::strcmp(argv[1], "--compare") == 0)
    {
        const uint32_t iterations = argc == 3
            ? static_cast<uint32_t>(std::strtoul(argv[2], nullptr, 10))
            : 2000000;
        if (iterations == 0)
        {
            std::fprintf(stderr, "comparison iteration count must be positive\n");
            return EXIT_FAILURE;
        }

        benchmark_kernel(200000, baseline_verusclhashv2_2, false);
        benchmark_kernel(200000, verusclhashv2_2);
        double baseline_seconds = 0;
        double candidate_seconds = 0;
        for (unsigned int round = 0; round < 6; ++round)
        {
            double baseline;
            double candidate;
            if ((round & 1) == 0)
            {
                baseline = benchmark_kernel(
                    iterations, baseline_verusclhashv2_2, false);
                candidate = benchmark_kernel(iterations, verusclhashv2_2);
            }
            else
            {
                candidate = benchmark_kernel(iterations, verusclhashv2_2);
                baseline = benchmark_kernel(
                    iterations, baseline_verusclhashv2_2, false);
            }
            baseline_seconds += baseline;
            candidate_seconds += candidate;
            std::printf("round %u: baseline %.6fs, candidate %.6fs, delta %+.3f%%\n",
                        round + 1,
                        baseline,
                        candidate,
                        ((baseline / candidate) - 1.0) * 100.0);
        }
        std::printf("aggregate: baseline %.6fs, candidate %.6fs, delta %+.3f%%\n",
                    baseline_seconds,
                    candidate_seconds,
                    ((baseline_seconds / candidate_seconds) - 1.0) * 100.0);
        return EXIT_SUCCESS;
    }
#endif

#ifdef ARM
#ifdef VERUS_HAVE_BASELINE
    if (argc >= 2 && std::strcmp(argv[1], "--bench-dual-baseline") == 0)
    {
        const uint32_t iterations = argc == 3
            ? static_cast<uint32_t>(std::strtoul(argv[2], nullptr, 10))
            : 1000000;
        if (iterations == 0 || (iterations & 1) != 0)
        {
            std::fprintf(
                stderr,
                "dual benchmark iteration count must be positive and even\n");
            return EXIT_FAILURE;
        }

        const auto result =
            benchmark_dual_kernel<baseline_verusclhashv2_2_dual>(iterations);
        std::printf("%u hashes in %.6f seconds: %.3f H/s\n",
                    iterations,
                    result.seconds,
                    iterations / result.seconds);
        return EXIT_SUCCESS;
    }
#endif

    if (argc >= 2 && std::strcmp(argv[1], "--bench-dual") == 0)
    {
        const uint32_t iterations = argc == 3
            ? static_cast<uint32_t>(std::strtoul(argv[2], nullptr, 10))
            : 1000000;
        if (iterations == 0 || (iterations & 1) != 0)
        {
            std::fprintf(
                stderr, "dual benchmark iteration count must be positive and even\n");
            return EXIT_FAILURE;
        }

        const auto result =
            benchmark_dual_kernel<verusclhashv2_2_dual>(iterations);
        std::printf("%u hashes in %.6f seconds: %.3f H/s\n",
                    iterations,
                    result.seconds,
                    iterations / result.seconds);
        return EXIT_SUCCESS;
    }
#endif

    if (argc >= 2 && std::strcmp(argv[1], "--bench") == 0)
    {
        const uint32_t iterations = argc == 3
            ? static_cast<uint32_t>(std::strtoul(argv[2], nullptr, 10))
            : 1000000;
        if (iterations == 0)
        {
            std::fprintf(stderr, "benchmark iteration count must be positive\n");
            return EXIT_FAILURE;
        }

        const double seconds = benchmark_kernel(iterations);
        std::printf("%u hashes in %.6f seconds: %.3f H/s\n",
                    iterations,
                    seconds,
                    iterations / seconds);
        return EXIT_SUCCESS;
    }

    const bool dump = argc == 2 && std::strcmp(argv[1], "--dump") == 0;
#ifdef ARM
#ifdef VERUS_TESTING
    test_native_mulhrs();
#endif
    test_dual_kernel();
#ifdef VERUS_HAVE_BASELINE
    test_dual_baseline_state();
#endif
#endif
    const std::array<const char *, 4> expected = {
        "2f5c21a15f092b8894c7d4dea1e308de6b9c82bd1c8dae3506438179e917fdad",
        "35e9dcba6b3b9496a904ac8806b5f07701486e489aca778414be678785479db7",
        "948b64e8f178e10a4874a4bc99ed16e755eb8b791c0bec485d81ed3929df9144",
        "2270ba2abe1cfea8509bc7b9bce389cb7b249accb5ab0dc43923eb2587120fd1",
    };

    for (uint32_t i = 0; i < expected.size(); ++i)
    {
        const auto actual = hash_vector(i);
        if (dump)
        {
            print_hex(actual);
            std::putchar('\n');
            continue;
        }

        char actual_hex[65] = {};
        for (size_t j = 0; j < actual.size(); ++j)
            std::snprintf(actual_hex + (j * 2), 3, "%02x", actual[j]);
        if (std::strcmp(actual_hex, expected[i]) != 0)
        {
            std::fprintf(stderr,
                         "vector %u mismatch\nexpected: %s\nactual:   %s\n",
                         i,
                         expected[i],
                         actual_hex);
            return EXIT_FAILURE;
        }
    }

    std::puts("Verus kernel vectors passed");
    return EXIT_SUCCESS;
}
