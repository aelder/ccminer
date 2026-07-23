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

#ifdef VERUS_HAVE_BASELINE
extern "C" uint64_t baseline_verusclhashv2_2(
    void *, const unsigned char *, uint64_t, uint32_t *, uint32_t *, u128 *, u128 *);
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
double benchmark_dual_kernel(uint32_t iterations)
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
        verusclhashv2_2_dual(
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
    return std::chrono::duration<double>(stopped - started).count();
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

        const double seconds = benchmark_dual_kernel(iterations);
        std::printf("%u hashes in %.6f seconds: %.3f H/s\n",
                    iterations,
                    seconds,
                    iterations / seconds);
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
