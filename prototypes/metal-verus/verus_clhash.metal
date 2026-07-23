// Experimental Apple Metal port of the Apache-2.0 Verus CLHash core.
// The current CPU implementation remains the consensus oracle.

#include <metal_stdlib>
using namespace metal;

constant uint kKeyVectors = 552;
constant uint kSteps = 32;
constant uchar kReductionBytes[16] = {
    0x00, 0x1b, 0x36, 0x2d, 0x6c, 0x77, 0x5a, 0x41,
    0xd8, 0xc3, 0xee, 0xf5, 0xb4, 0xaf, 0x82, 0x99
};

inline ulong low64(uint4 value)
{
    return ulong(value.x) | (ulong(value.y) << 32);
}

inline ulong high64(uint4 value)
{
    return ulong(value.z) | (ulong(value.w) << 32);
}

inline uint4 from64(ulong low, ulong high)
{
    return uint4(uint(low), uint(low >> 32), uint(high), uint(high >> 32));
}

inline uint4 clmul64(ulong a, ulong b)
{
    ulong multiples[16];
    multiples[0] = 0;
    multiples[1] = b;
    for (uint i = 2; i < 16; i += 2) {
        multiples[i] = multiples[i >> 1] << 1;
        multiples[i + 1] = multiples[i] ^ b;
    }

    ulong low = multiples[a & 15];
    ulong high = 0;
    for (uint shift = 4; shift < 64; shift += 4) {
        const ulong part = multiples[(a >> shift) & 15];
        low ^= part << shift;
        high ^= part >> (64 - shift);
    }

    ulong repair_mask = 0xeeeeeeeeeeeeeeeeUL;
    for (uint i = 1; i < 4; ++i) {
        const ulong crossed = (a & repair_mask) >> i;
        repair_mask &= repair_mask << 1;
        const ulong include = ulong(0) - ((b >> (64 - i)) & 1);
        high ^= crossed & include;
    }
    return from64(low, high);
}

inline uint4 clmul_cross(uint4 value)
{
    return clmul64(low64(value), high64(value));
}

inline uint mulhrs_word(uint left, uint right)
{
    const int left_low = int(short(left & 0xffffu));
    const int left_high = int(short(left >> 16));
    const int right_low = int(short(right & 0xffffu));
    const int right_high = int(short(right >> 16));
    const int low_product = (left_low * right_low + 0x4000) >> 15;
    const int high_product = (left_high * right_high + 0x4000) >> 15;
    return (uint(low_product) & 0xffffu) |
           ((uint(high_product) & 0xffffu) << 16);
}

inline uint4 mulhrs(uint4 left, uint4 right)
{
    return uint4(
        mulhrs_word(left.x, right.x),
        mulhrs_word(left.y, right.y),
        mulhrs_word(left.z, right.z),
        mulhrs_word(left.w, right.w));
}

inline uint4 unpack_low(uint4 left, uint4 right)
{
    return uint4(left.x, right.x, left.y, right.y);
}

inline uint4 unpack_high(uint4 left, uint4 right)
{
    return uint4(left.z, right.z, left.w, right.w);
}

inline void mix2(thread uint4 &left, thread uint4 &right)
{
    const uint4 low = unpack_low(left, right);
    right = unpack_high(left, right);
    left = low;
}

inline void aesenc(
    thread uint4 &state,
    uint4 round_key,
    const device uint *tables)
{
    uint x0 = state.x;
    uint x1 = state.y;
    uint x2 = state.z;
    uint x3 = state.w;

    uint y0 = tables[x0 & 0xffu];
    uint y1 = tables[x1 & 0xffu];
    uint y2 = tables[x2 & 0xffu];
    uint y3 = tables[x3 & 0xffu];
    x0 >>= 8;
    x1 >>= 8;
    x2 >>= 8;
    x3 >>= 8;

    const uint t10 = tables[x1 & 0xffu];
    const uint t11 = tables[x2 & 0xffu];
    const uint t12 = tables[x3 & 0xffu];
    const uint t13 = tables[x0 & 0xffu];
    y0 ^= (t10 << 8) | (t10 >> 24);
    y1 ^= (t11 << 8) | (t11 >> 24);
    y2 ^= (t12 << 8) | (t12 >> 24);
    y3 ^= (t13 << 8) | (t13 >> 24);
    x0 >>= 8;
    x1 >>= 8;
    x2 >>= 8;
    x3 >>= 8;

    const uint t20 = tables[x2 & 0xffu];
    const uint t21 = tables[x3 & 0xffu];
    const uint t22 = tables[x0 & 0xffu];
    const uint t23 = tables[x1 & 0xffu];
    y0 ^= (t20 << 16) | (t20 >> 16);
    y1 ^= (t21 << 16) | (t21 >> 16);
    y2 ^= (t22 << 16) | (t22 >> 16);
    y3 ^= (t23 << 16) | (t23 >> 16);
    x0 >>= 8;
    x1 >>= 8;
    x2 >>= 8;
    x3 >>= 8;

    const uint t30 = tables[x3];
    const uint t31 = tables[x0];
    const uint t32 = tables[x1];
    const uint t33 = tables[x2];
    y0 ^= (t30 << 24) | (t30 >> 8);
    y1 ^= (t31 << 24) | (t31 >> 8);
    y2 ^= (t32 << 24) | (t32 >> 8);
    y3 ^= (t33 << 24) | (t33 >> 8);
    state = uint4(y0, y1, y2, y3) ^ round_key;
}

inline void aes2(
    thread uint4 &left,
    thread uint4 &right,
    device uint4 *round_keys,
    uint offset,
    const device uint *tables)
{
    aesenc(left, round_keys[offset], tables);
    aesenc(right, round_keys[offset + 1], tables);
    aesenc(left, round_keys[offset + 2], tables);
    aesenc(right, round_keys[offset + 3], tables);
}

inline void aes4(
    thread uint4 &s0,
    thread uint4 &s1,
    thread uint4 &s2,
    thread uint4 &s3,
    device uint4 *round_keys,
    uint offset,
    const device uint *tables)
{
    aesenc(s0, round_keys[offset], tables);
    aesenc(s1, round_keys[offset + 1], tables);
    aesenc(s2, round_keys[offset + 2], tables);
    aesenc(s3, round_keys[offset + 3], tables);
    aesenc(s0, round_keys[offset + 4], tables);
    aesenc(s1, round_keys[offset + 5], tables);
    aesenc(s2, round_keys[offset + 6], tables);
    aesenc(s3, round_keys[offset + 7], tables);
}

inline void mix4(
    thread uint4 &s0,
    thread uint4 &s1,
    thread uint4 &s2,
    thread uint4 &s3)
{
    const uint4 temporary = unpack_low(s0, s1);
    s0 = unpack_high(s0, s1);
    s1 = unpack_low(s2, s3);
    s2 = unpack_high(s2, s3);
    s3 = unpack_low(s0, s2);
    s0 = unpack_high(s0, s2);
    s2 = unpack_high(s1, temporary);
    s1 = unpack_low(s1, temporary);
}

inline uint keyed_haraka_highword(
    thread uint4 *input,
    device uint4 *round_keys,
    const device uint *tables)
{
    uint4 s0 = input[0];
    uint4 s1 = input[1];
    uint4 s2 = input[2];
    uint4 s3 = input[3];

    aes4(s0, s1, s2, s3, round_keys, 0, tables);
    mix4(s0, s1, s2, s3);
    aes4(s0, s1, s2, s3, round_keys, 8, tables);
    mix4(s0, s1, s2, s3);
    aes4(s0, s1, s2, s3, round_keys, 16, tables);
    mix4(s0, s1, s2, s3);
    aes4(s0, s1, s2, s3, round_keys, 24, tables);

    const uint4 temporary = unpack_low(s0, s1);
    s1 = unpack_low(s2, s3);
    s2 = unpack_high(s1, temporary);
    aesenc(s2, round_keys[34], tables);
    aesenc(s2, round_keys[38], tables);
    return s2.z ^ input[3].y;
}

inline ulong reduce64(uint4 accumulator)
{
    const uint4 q2 = clmul64(high64(accumulator), 27);
    const ulong q2_high = high64(q2);

    ulong shuffled = 0;
    for (uint i = 0; i < 8; ++i) {
        const uchar selector = uchar(q2_high >> (i * 8));
        const uchar value =
            (selector & 0x80u) ? 0 : kReductionBytes[selector & 0x0fu];
        shuffled |= ulong(value) << (i * 8);
    }
    return low64(accumulator) ^ low64(q2) ^ shuffled;
}

kernel void prepare_keys(
    const device uint4 *pristine [[buffer(0)]],
    device uint4 *keys [[buffer(1)]],
    constant uint &count [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= kKeyVectors || gid.y >= count)
        return;
    keys[gid.y * kKeyVectors + gid.x] = pristine[gid.x];
}

kernel void restore_keys(
    const device uint4 *pristine [[buffer(0)]],
    device uint4 *keys [[buffer(1)]],
    const device uint *touched [[buffer(2)]],
    constant uint &count [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= count)
        return;
    device uint4 *key = keys + gid * kKeyVectors;
    const device uint *lane_touched = touched + gid * kSteps;
    for (uint step = 0; step < kSteps; ++step) {
        const uint packed = lane_touched[step];
        const uint first = packed & 0xffffu;
        const uint second = packed >> 16;
        key[first] = pristine[first];
        key[second] = pristine[second];
    }
}

kernel void primitive_probe(
    const device uint4 *left [[buffer(0)]],
    const device uint4 *right [[buffer(1)]],
    device uint4 *clmul_results [[buffer(2)]],
    device uint4 *mulhrs_results [[buffer(3)]],
    device ulong *reduction_results [[buffer(4)]],
    constant uint &count [[buffer(5)]],
    const device uint *tables [[buffer(6)]],
    device uint4 *aes_results [[buffer(7)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= count)
        return;
    clmul_results[gid] = clmul_cross(left[gid]);
    mulhrs_results[gid] = mulhrs(left[gid], right[gid]);
    reduction_results[gid] = reduce64(left[gid]);
    uint4 aes_state = left[gid];
    aesenc(aes_state, right[gid], tables);
    aes_results[gid] = aes_state;
}

kernel void verus_clhash_batch(
    device uint4 *keys [[buffer(0)]],
    const device uint4 *inputs [[buffer(1)]],
    device ulong *results [[buffer(2)]],
    device uint *touched [[buffer(3)]],
    constant uint &count [[buffer(4)]],
    const device uint *tables [[buffer(5)]],
    device uint *case_masks [[buffer(6)]],
    device uint *highwords [[buffer(7)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= count)
        return;

    device uint4 *randomsource = keys + gid * kKeyVectors;
    const device uint4 *input = inputs + gid * 4;
    thread uint4 pbuf_copy[4];
    pbuf_copy[0] = input[0] ^ input[2];
    pbuf_copy[1] = input[1] ^ input[3];
    pbuf_copy[2] = input[2];
    pbuf_copy[3] = input[3];

    uint4 accumulator = randomsource[513];
    uint case_mask = 0;

    for (uint step = 0; step < kSteps; ++step) {
        const ulong selector = low64(accumulator);
        const uint prand_index = uint((selector >> 5) & 511);
        const uint prandex_index = uint((selector >> 32) & 511);
        device uint4 *prand = randomsource + prand_index;
        device uint4 *prandex = randomsource + prandex_index;
        thread uint4 *pbuf = pbuf_copy + (selector & 3);
        touched[gid * kSteps + step] =
            prand_index | (prandex_index << 16);

        const uint selected_case = uint((selector >> 2) & 7);
        case_mask |= 1u << selected_case;
        switch (selected_case) {
        case 0: {
            const uint4 temp1 = *prandex;
            const uint4 temp2 = pbuf[(selector & 1) ? -1 : 1];
            accumulator ^= clmul_cross(temp1 ^ temp2);
            const uint4 next_prand = mulhrs(accumulator, temp1) ^ temp1;

            const uint4 old_prand = *prand;
            *prand = next_prand;
            const uint4 temp22 = *pbuf;
            accumulator ^= clmul_cross(old_prand ^ temp22);
            *prandex = mulhrs(accumulator, old_prand) ^ old_prand;
            break;
        }
        case 1: {
            const uint4 temp1 = *prand;
            const uint4 temp2 = *pbuf;
            accumulator ^= clmul_cross(temp1 ^ temp2);
            accumulator ^= clmul_cross(temp2);
            const uint4 next_prandex = mulhrs(accumulator, temp1) ^ temp1;

            const uint4 old_prandex = *prandex;
            *prandex = next_prandex;
            accumulator ^= old_prandex ^
                pbuf[(selector & 1) ? -1 : 1];
            *prand = mulhrs(accumulator, old_prandex) ^ old_prandex;
            break;
        }
        case 2: {
            const uint4 temp1 = *prandex;
            const uint4 temp2 = *pbuf;
            accumulator ^= temp1 ^ temp2;
            const uint4 next_prand = mulhrs(accumulator, temp1) ^ temp1;

            const uint4 old_prand = *prand;
            *prand = next_prand;
            const uint4 temp22 = pbuf[(selector & 1) ? -1 : 1];
            accumulator ^= clmul_cross(old_prand ^ temp22);
            accumulator ^= clmul_cross(temp22);
            *prandex = mulhrs(accumulator, old_prand) ^ old_prand;
            break;
        }
        case 3: {
            const uint4 temp1 = *prand;
            const uint4 temp2 = pbuf[(selector & 1) ? -1 : 1];
            accumulator ^= temp1 ^ temp2;
            const int divisor = as_type<int>(uint(selector));
            const long dividend = as_type<long>(low64(accumulator));
            const int remainder = int(dividend % long(divisor));
            accumulator.x ^= as_type<uint>(remainder);
            const uint4 next_prandex = mulhrs(accumulator, temp1) ^ temp1;

            if (dividend & 1) {
                const uint4 old_prandex = *prandex;
                *prandex = next_prandex;
                const uint4 temp22 = *pbuf;
                accumulator ^= clmul_cross(old_prandex ^ temp22);
                accumulator ^= clmul_cross(temp22);
                *prand = mulhrs(accumulator, old_prandex) ^ old_prandex;
            } else {
                *prand = *prandex;
                *prandex = next_prandex;
                accumulator ^= *pbuf;
            }
            break;
        }
        case 4: {
            device uint4 *round_keys = prand;
            uint4 left = pbuf[(selector & 1) ? -1 : 1];
            uint4 right = *pbuf;
            aes2(left, right, round_keys, 0, tables);
            mix2(left, right);
            aes2(left, right, round_keys, 4, tables);
            mix2(left, right);
            aes2(left, right, round_keys, 8, tables);
            mix2(left, right);
            accumulator ^= left ^ right;

            const uint4 old_prand = *prand;
            const uint4 next_prandex =
                mulhrs(accumulator, old_prand) ^ old_prand;
            *prand = *prandex;
            *prandex = next_prandex;
            break;
        }
        case 5: {
            thread uint4 *alternate =
                pbuf + ((selector & 1) ? -1 : 1);
            uint rounds = uint(selector >> 61);
            device uint4 *round_keys = prand;
            uint aes_offset = 0;
            do {
                if (selector & (ulong(0x10000000u) << rounds)) {
                    const uint4 temp2 =
                        (rounds & 1) ? *pbuf : *alternate;
                    accumulator ^= clmul_cross(*round_keys ^ temp2);
                    ++round_keys;
                } else {
                    uint4 left = *round_keys++;
                    uint4 right = (rounds & 1) ? *alternate : *pbuf;
                    aes2(left, right, round_keys, aes_offset, tables);
                    aes_offset += 4;
                    mix2(left, right);
                    accumulator ^= left ^ right;
                }
            } while (rounds--);

            const uint4 old_prand = *prand;
            const uint4 next_prandex =
                mulhrs(accumulator, old_prand) ^ old_prand;
            const uint4 old_prandex = *prandex;
            *prandex = next_prandex;
            *prand = old_prandex;
            break;
        }
        case 6: {
            thread uint4 *alternate =
                pbuf + ((selector & 1) ? -1 : 1);
            uint rounds = uint(selector >> 61);
            device uint4 *round_keys = prand;
            uint4 one_key = uint4(0);
            do {
                if (selector & (ulong(0x10000000u) << rounds)) {
                    const uint4 temp2 =
                        (rounds & 1) ? *pbuf : *alternate;
                    one_key = *round_keys++ ^ temp2;
                    const int divisor = as_type<int>(uint(selector));
                    const long dividend = as_type<long>(low64(one_key));
                    const int remainder = int(dividend % long(divisor));
                    accumulator.x ^= as_type<uint>(remainder);
                } else {
                    const uint4 temp2 =
                        (rounds & 1) ? *alternate : *pbuf;
                    one_key = clmul_cross(*round_keys++ ^ temp2);
                    accumulator ^= mulhrs(accumulator, one_key);
                }
            } while (rounds--);

            const uint4 old_prandex = *prandex;
            *prandex = one_key;
            *prand = old_prandex ^ accumulator;
            break;
        }
        default: {
            const uint4 temp1 = *pbuf;
            const uint4 temp2 = *prandex;
            accumulator ^= clmul_cross(temp1 ^ temp2);
            const uint4 next_prand =
                mulhrs(accumulator, temp2) ^ temp2;
            const uint4 old_prand = *prand;
            *prand = next_prand;
            accumulator ^= old_prand;
            accumulator ^= pbuf[(selector & 1) ? -1 : 1];
            *prandex =
                mulhrs(accumulator, old_prand) ^ old_prand;
            break;
        }
        }
    }

    accumulator.x ^= 0x00010000u;
    const ulong intermediate = reduce64(accumulator);
    results[gid] = intermediate;
    case_masks[gid] = case_mask;

    thread uint4 final_input[4];
    final_input[0] = input[0];
    final_input[1] = input[1];
    final_input[2] = input[2];
    const ulong rotated = (intermediate >> 8) | (intermediate << 56);
    final_input[3] = from64(rotated, rotated);
    final_input[2].w =
        (final_input[2].w & 0x00ffffffu) |
        (uint(intermediate) & 0xffu) << 24;
    highwords[gid] = keyed_haraka_highword(
        final_input, randomsource + (intermediate & 511), tables);
}
