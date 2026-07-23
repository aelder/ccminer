/**
* Equihash solver interface for ccminer (compatible with linux and windows)
* Solver taken from nheqminer, by djeZo (and NiceHash)
* tpruvot - 2017 (GPL v3)
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
#include <pthread.h>
#define VERUS_KEY_SIZE 8832
#define VERUS_KEY_SIZE128 552
#define VERUS_KEY_SCRATCH_SIZE 1024
#define VERUS_KEY_ALLOCATION_SIZE (VERUS_KEY_SIZE + VERUS_KEY_SCRATCH_SIZE)
#define VERUS_KEY_ALLOCATION_SIZE128 (VERUS_KEY_ALLOCATION_SIZE / sizeof(u128))
#ifdef ARM
#define VERUS_BATCH_LANES 2
#else
#define VERUS_BATCH_LANES 1
#endif
#include <stdexcept>
#include <vector>
#include "verus_clhash.h"
#include "uint256.h"
//#include "hash.h"
#include <miner.h>
//#include "primitives/block.h"
//extern "C"
//{
//#include "haraka.h"

//}
enum
{
	// primary actions
	SER_NETWORK = (1 << 0),
	SER_DISK = (1 << 1),
	SER_GETHASH = (1 << 2),
};
// input here is 140 for the header and 1344 for the solution (equi.cpp)
static const int PROTOCOL_VERSION = 170002;

//#include <cuda_helper.h>

#define EQNONCE_OFFSET 30 /* 27:34 */
#define NONCE_OFT EQNONCE_OFFSET

static bool init[MAX_GPUS] = { 0 };
static pthread_once_t haraka_constants_once = PTHREAD_ONCE_INIT;

static void InitializeHarakaConstants()
{
	load_constants();
}

#ifndef htobe32
#define htobe32(x) swab32(x)
#endif

extern "C" inline void GenNewCLKey(unsigned char *seedBytes32, u128 *keyback)
{
	// generate a new key by chain hashing with Haraka256 from the last curbuf
	int n256blks = VERUS_KEY_SIZE >> 5;  //8832 >> 5
	int nbytesExtra = VERUS_KEY_SIZE & 0x1f;  //8832 & 0x1f
	unsigned char *pkey = (unsigned char*)keyback;
	unsigned char *psrc = seedBytes32;
	for (int i = 0; i < n256blks; i++)
	{
		haraka256(pkey, psrc);

		psrc = pkey;
		pkey += 32;
	}
	if (nbytesExtra)
	{
		unsigned char buf[32];
		haraka256(buf, psrc);
		memcpy(pkey, buf, nbytesExtra);
	}
}

extern "C" inline void FixKey(uint32_t *fixrand, uint32_t *fixrandex, u128 *keyback,
	u128 * g_prand, u128 *g_prandex)
{

	for (int i = 31; i > -1; i--)
	{
		keyback[fixrandex[i]] = g_prandex[i];
		keyback[fixrand[i]] = g_prand[i];
	}

}

#ifdef ARM
static inline void RestoreKey(
	const uint32_t *touched, u128 *key, const u128 *pristine)
{
	for (int i = 0; i < 32; ++i)
	{
		const uint32_t packed = touched[i];
		const uint32_t first = packed & 0xffff;
		const uint32_t second = packed >> 16;
		key[first] = pristine[first];
		key[second] = pristine[second];
	}
}
#endif


 extern "C" inline void VerusHashHalf(void *result2, unsigned char *data, int len)
{
	alignas(32) unsigned char buf1[64] = { 0 }, buf2[64];
	unsigned char *curBuf = buf1, *result = buf2;
	int curPos = 0;
	//unsigned char result[64];
	curBuf = buf1;
	result = buf2;
	curPos = 0;
	std::fill(buf1, buf1 + sizeof(buf1), 0);

	unsigned char *tmp;

	pthread_once(&haraka_constants_once, InitializeHarakaConstants);

	// digest up to 32 bytes at a time
	for (int pos = 0; pos < len; )
	{
		int room = 32 - curPos;

		if (len - pos >= room)
		{
			memcpy(curBuf + 32 + curPos, data + pos, room);
			haraka512(result, curBuf);
			tmp = curBuf;
			curBuf = result;
			result = tmp;
			pos += room;
			curPos = 0;
		}
		else
		{
			memcpy(curBuf + 32 + curPos, data + pos, len - pos);
			curPos += len - pos;
			pos = len;
		}
	}

	memcpy(curBuf + 47, curBuf, 16);
	memcpy(curBuf + 63, curBuf, 1);
	//	FillExtra((u128 *)curBuf);
	memcpy(result2, curBuf, 64);
};




static inline void PrepareHashInput(
	unsigned char *curBuf, u128 fill1, unsigned char first_byte, uint32_t nonce)
{
	_mm_store_si128((u128 *)(&curBuf[32 + 16]), fill1);
	curBuf[32 + 15] = first_byte;
	memcpy(curBuf + 43, &nonce, sizeof(nonce));
}

static inline bool FinalizeHash(
	unsigned char *hash, unsigned char *curBuf, const uint32_t *target,
	uint32_t high_target, u128 *data_key, uint64_t intermediate)
{
#ifdef ARM
	const uint8x16_t repeated = vreinterpretq_u8_u64(vdupq_n_u64(intermediate));
	const __m128i fill2 = vreinterpretq_m128i_u8(
		vextq_u8(repeated, repeated, 1));
#else
	static const __m128i shuf2 =
		_mm_setr_epi8(1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0);
	__m128i fill2 = _mm_shuffle_epi8(_mm_loadl_epi64((u128 *)&intermediate), shuf2);
#endif
	_mm_store_si128((u128 *)(&curBuf[32 + 16]), fill2);
	curBuf[32 + 15] = *((unsigned char *)&intermediate);
	intermediate &= 511;
	const u128 *key = data_key + intermediate;
	const uint32_t highword = haraka512_keyed_highword(curBuf, key);
	bool valid = false;
	if (unlikely(highword <= high_target))
	{
		haraka512_keyed(hash, curBuf, key);
		valid = fulltest((uint32_t *)hash, target);
	}
	return valid;
}

extern "C" bool inline Verus2hash(unsigned char *hash, unsigned char *curBuf,
	const uint32_t *target, uint32_t high_target,
	u128 *__restrict data_key,
#ifdef ARM
	const u128 *pristine_key, uint32_t *touched)
#else
	uint32_t *fixrand, uint32_t *fixrandex, u128 *g_prand, u128 *g_prandex)
#endif
{
#ifdef ARM
	const uint64_t intermediate = verusclhashv2_2(
		data_key, curBuf, 511, touched, NULL, NULL, NULL);
	const bool valid = FinalizeHash(
		hash, curBuf, target, high_target, data_key, intermediate);
	RestoreKey(touched, data_key, pristine_key);
#else
	const uint64_t intermediate = verusclhashv2_2(
		data_key, curBuf, 511, fixrand, fixrandex, g_prand, g_prandex);
	const bool valid = FinalizeHash(
		hash, curBuf, target, high_target, data_key, intermediate);
	FixKey(fixrand, fixrandex, data_key, g_prand, g_prandex);
#endif
	return valid;
}


extern "C" int scanhash_verus(int thr_id, struct work *work, uint32_t max_nonce, unsigned long *hashes_done)
{

	uint32_t *pdata = work->data;
	uint32_t *ptarget = work->target;
	const uint32_t high_target = ptarget[7];
	alignas(32) uint8_t blockhash_half[VERUS_BATCH_LANES][64] = { 0 };
#ifdef ARM
	u128 *key_storage = (u128 *)malloc(
		(VERUS_BATCH_LANES + 1) * VERUS_KEY_SIZE);
#else
	u128 *key_storage = (u128 *)malloc(
		VERUS_BATCH_LANES * VERUS_KEY_ALLOCATION_SIZE);
#endif
	if (!key_storage)
	{
		*hashes_done = 0;
		return 0;
	}
	u128 *data_key[VERUS_BATCH_LANES];
#ifdef ARM
	for (int lane = 0; lane < VERUS_BATCH_LANES; ++lane)
		data_key[lane] = key_storage + (lane * VERUS_KEY_SIZE128);
	u128 *pristine_key =
		key_storage + (VERUS_BATCH_LANES * VERUS_KEY_SIZE128);
	uint32_t touched[VERUS_BATCH_LANES][32];
#else
	u128 *data_key_prand[VERUS_BATCH_LANES];
	u128 *data_key_prandex[VERUS_BATCH_LANES];
	for (int lane = 0; lane < VERUS_BATCH_LANES; ++lane)
	{
		data_key[lane] =
			key_storage + (lane * VERUS_KEY_ALLOCATION_SIZE128);
		data_key_prand[lane] = data_key[lane] + VERUS_KEY_SIZE128;
		data_key_prandex[lane] = data_key_prand[lane] + 32;
	}

	uint32_t fixrand[VERUS_BATCH_LANES][32];
	uint32_t fixrandex[VERUS_BATCH_LANES][32];
#endif
	uint32_t nonce_buf = 0;

	unsigned char block_41970[3] = { 0xfd, 0x40, 0x05};
	uint8_t  full_data[140 + 3 + 1344] = { 0 };
	uint8_t* sol_data = &full_data[140];

	memcpy(full_data, pdata, 140);
	memcpy(sol_data, block_41970, 3);
	memcpy(sol_data + 3, work->solution, 1344);
	uint8_t version = work->solution[0];
	uint8_t nonceSpace[15] = {0};  //pool nonce (32bit) + round(32bit) + thrd id (byte) + padding(2bytes) + counting nonce(32bit)
	
    if (version >= 7 && work->solution[5] > 0) {

        // clear non-canonical data from header/solution before hashing; required for merged mining 
		memset(full_data + 4, 0, 96);                        // hashPrevBlock, hashMerkleRoot, hashFinalSaplingRoot
        memset(full_data + 4 + 32 + 32 + 32 + 4, 0, 4);      // nBits
        memset(full_data + 4 + 32 + 32 + 32 + 4 + 4, 0, 32); // nNonce
        memset(sol_data + 3 + 8, 0, 64);                     // hashPrevMMRRoot, hashBlockMMRRoot
		memcpy(nonceSpace, &pdata[EQNONCE_OFFSET - 3], 7 );			// transfer the nonce values that would be in the header to
//		memcpy(nonceSpace + 4, &pdata[EQNONCE_OFFSET + 1], 3 );		// the 15 bytes available
		memcpy(nonceSpace + 7, &pdata[EQNONCE_OFFSET + 2], 4 );	
	}

	uint32_t  vhash[8] = { 0 };

	VerusHashHalf(blockhash_half[0], (unsigned char*)full_data, 1487);

	GenNewCLKey((unsigned char*)blockhash_half[0], data_key[0]);
#ifdef ARM
	memcpy(pristine_key, data_key[0], VERUS_KEY_SIZE);
#endif
	for (int lane = 1; lane < VERUS_BATCH_LANES; ++lane)
	{
		memcpy(blockhash_half[lane], blockhash_half[0], 64);
		memcpy(data_key[lane],
#ifdef ARM
			pristine_key,
#else
			data_key[0],
#endif
			VERUS_KEY_SIZE);
	}
	for (int lane = 0; lane < VERUS_BATCH_LANES; ++lane)
		memcpy(blockhash_half[lane] + 32, nonceSpace, 11);
#ifdef ARM
	const uint8x16_t first_block =
		vreinterpretq_u8_m128i(_mm_load_si128((u128 *)blockhash_half[0]));
	const u128 fill1 = vreinterpretq_m128i_u8(
		vextq_u8(first_block, first_block, 1));
#else
	const u128 shuf1 =
		_mm_setr_epi8(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0);
	const u128 fill1 =
		_mm_shuffle_epi8(_mm_load_si128((u128 *)blockhash_half[0]), shuf1);
#endif
	const unsigned char first_byte = blockhash_half[0][0];
	const uint64_t hash_limit = max_nonce ? max_nonce : 1;
	uint64_t completed = 0;
	auto record_solution = [&](uint32_t solution_nonce) {
		memcpy(nonceSpace + 11, &solution_nonce, sizeof(solution_nonce));
		work->valid_nonces++;
		memcpy(work->data, full_data, 140);
		int nonce = work->valid_nonces - 1;
		memcpy(work->extra, sol_data, 1347);
		memcpy(work->extra + 1332, nonceSpace, 15);
		bn_store_hash_target_ratio(vhash, work->target, work, nonce);
		work->nonces[nonce] = ((uint32_t*)full_data)[NONCE_OFT];
	};

#ifdef ARM
	while (completed + VERUS_BATCH_LANES <= hash_limit)
	{
		for (int lane = 0; lane < VERUS_BATCH_LANES; ++lane)
			PrepareHashInput(
				blockhash_half[lane], fill1, first_byte, nonce_buf + lane);

		uint64_t intermediate[VERUS_BATCH_LANES];
		verusclhashv2_2_dual(
			data_key[0], blockhash_half[0], touched[0],
			data_key[1], blockhash_half[1], touched[1], intermediate);

		bool found = false;
		uint32_t found_nonce = 0;
		for (int lane = 0; lane < VERUS_BATCH_LANES; ++lane)
		{
			uint32_t candidate_hash[8];
			const bool lane_found = FinalizeHash(
				(unsigned char *)candidate_hash, blockhash_half[lane], ptarget,
				high_target, data_key[lane], intermediate[lane]);
			if (lane_found && !found)
			{
				memcpy(vhash, candidate_hash, sizeof(vhash));
				found = true;
				found_nonce = nonce_buf + lane;
			}
		}
		for (int lane = 0; lane < VERUS_BATCH_LANES; ++lane)
			RestoreKey(touched[lane], data_key[lane], pristine_key);

		completed += VERUS_BATCH_LANES;
		nonce_buf += VERUS_BATCH_LANES;
		if (found)
		{
			record_solution(found_nonce);
			goto out;
		}
		if ((completed & 0x1ff) == 0 &&
			(work_restart[thr_id].restart || abort_flag))
			goto out;
	}
#endif

	while (completed < hash_limit)
	{
		PrepareHashInput(blockhash_half[0], fill1, first_byte, nonce_buf);
		const bool valid = Verus2hash(
				(unsigned char *)vhash, blockhash_half[0], ptarget,
				high_target,
				data_key[0],
#ifdef ARM
				pristine_key, touched[0]);
#else
				fixrand[0], fixrandex[0],
				data_key_prand[0], data_key_prandex[0]);
#endif
		++completed;

		if (valid)
		{
			record_solution(nonce_buf);
			goto out;
		}

		++nonce_buf;
		if ((completed & 0x1ff) == 0 &&
			(work_restart[thr_id].restart || abort_flag))
			break;
	}


out:
	*hashes_done = completed;
	pdata[NONCE_OFT] = ((uint32_t*)full_data)[NONCE_OFT] + 1;
	free(key_storage);

	return work->valid_nonces;
}

// cleanup
void free_verushash(int thr_id)
{
	if (!init[thr_id])
		return;



	init[thr_id] = false;
}
