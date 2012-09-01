/******************************************************************************
 * 
 * Copyright (c) 2010-2012, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2012, NVIDIA CORPORATION.  All rights reserved.
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 ******************************************************************************/

/******************************************************************************
 *
 ******************************************************************************/

#pragma once

#include "../../cub/cub.cuh"
#include "../ns_wrapper.cuh"

#include "sort_utils.cuh"
#include "cta_single_tile.cuh"
#include "cta_downsweep_pass.cuh"
#include "cta_upsweep_pass.cuh"


BACK40_NS_PREFIX
namespace back40 {
namespace radix_sort {

//---------------------------------------------------------------------
// Tuning policy types
//---------------------------------------------------------------------


/**
 * Hybrid CTA tuning policy
 */
template <
	int 						RADIX_BITS,						// The number of radix bits, i.e., log2(bins)
	int 						_CTA_THREADS,					// The number of threads per CTA

	int 						UPSWEEP_THREAD_ITEMS,			// The number of consecutive upsweep items to load per thread per tile
	int 						DOWNSWEEP_THREAD_ITEMS,			// The number of consecutive downsweep items to load per thread per tile
	ScatterStrategy 			DOWNSWEEP_SCATTER_STRATEGY,		// Downsweep strategy
	int 						SINGLE_TILE_THREAD_ITEMS,		// The number of consecutive single-tile items to load per thread per tile

	cub::LoadModifier 			LOAD_MODIFIER,					// Load cache-modifier
	cub::StoreModifier			STORE_MODIFIER,					// Store cache-modifier
	cudaSharedMemConfig			_SMEM_CONFIG>					// Shared memory bank size
struct CtaHybridPassPolicy
{
	enum
	{
		CTA_THREADS = _CTA_THREADS,
	};

	static const cudaSharedMemConfig SMEM_CONFIG = _SMEM_CONFIG;

	// Upsweep pass policy
	typedef CtaUpsweepPassPolicy<
		RADIX_BITS,
		CTA_THREADS,
		UPSWEEP_THREAD_ITEMS,
		LOAD_MODIFIER,
		STORE_MODIFIER,
		SMEM_CONFIG> CtaUpsweepPassPolicyT;

	// Downsweep pass policy
	typedef CtaDownsweepPassPolicy<
		RADIX_BITS,
		CTA_THREADS,
		DOWNSWEEP_THREAD_ITEMS,
		DOWNSWEEP_SCATTER_STRATEGY,
		LOAD_MODIFIER,
		STORE_MODIFIER,
		SMEM_CONFIG> CtaDownsweepPassPolicyT;

	// Single tile policy
	typedef CtaSingleTilePolicy<
		RADIX_BITS,
		CTA_THREADS,
		SINGLE_TILE_THREAD_ITEMS,
		LOAD_MODIFIER,
		STORE_MODIFIER,
		SMEM_CONFIG> CtaSingleTilePolicyT;

	// Single tile policy
	typedef CtaSingleTilePolicy<
		RADIX_BITS,
		CTA_THREADS,
		1,
		LOAD_MODIFIER,
		STORE_MODIFIER,
		SMEM_CONFIG> CtaSingleTilePolicyT1;

};

//---------------------------------------------------------------------
// CTA-wide abstractions
//---------------------------------------------------------------------

/**
 * Kernel entry point
 */
template <
	typename 	CtaHybridPassPolicy,
	int 		MIN_CTA_OCCUPANCY,
	typename 	SizeT,
	typename 	KeyType,
	typename 	ValueType>
__launch_bounds__ (
	CtaHybridPassPolicy::CTA_THREADS,
	MIN_CTA_OCCUPANCY)
__global__
void HybridKernel(
	unsigned int						*d_queue_counters,
	unsigned int						*d_steal_counters,
	BinDescriptor						*d_bins_in,
	BinDescriptor						*d_bins_out,
	KeyType 							*d_keys_in,
	KeyType 							*d_keys_out,
	KeyType 							*d_keys_final,
	ValueType 							*d_values_in,
	ValueType 							*d_values_out,
	ValueType 							*d_values_final,
	unsigned int						low_bit,
	int 								iteration)
{
	enum
	{
		CTA_THREADS				= CtaHybridPassPolicy::CtaUpsweepPassPolicyT::CTA_THREADS,

		SWEEP_RADIX_BITS 		= CtaHybridPassPolicy::CtaUpsweepPassPolicyT::RADIX_BITS,
		SWEEP_RADIX_DIGITS		= 1 << SWEEP_RADIX_BITS,

		WARP_THREADS			= cub::DeviceProps::WARP_THREADS,

		SINGLE_TILE_ITEMS		= CtaHybridPassPolicy::CtaSingleTilePolicyT::TILE_ITEMS,
		SINGLE_TILE_ITEMS1		= CtaHybridPassPolicy::CtaSingleTilePolicyT1::TILE_ITEMS,
	};

	// CTA upsweep abstraction
	typedef CtaUpsweepPass<
		typename CtaHybridPassPolicy::CtaUpsweepPassPolicyT,
		KeyType,
		SizeT> CtaUpsweepPassT;

	// CTA downsweep abstraction
	typedef CtaDownsweepPass<
		typename CtaHybridPassPolicy::CtaDownsweepPassPolicyT,
		KeyType,
		ValueType,
		SizeT> CtaDownsweepPassT;

	// CTA single-tile abstraction
	typedef CtaSingleTile<
		typename CtaHybridPassPolicy::CtaSingleTilePolicyT,
		KeyType,
		ValueType> CtaSingleTileT;

	// CTA single-tile abstraction
	typedef CtaSingleTile<
		typename CtaHybridPassPolicy::CtaSingleTilePolicyT1,
		KeyType,
		ValueType> CtaSingleTileT1;

	// Warp scan abstraction
	typedef cub::WarpScan<
		SizeT,
		1,
		SWEEP_RADIX_DIGITS> WarpScanT;

	// CTA scan abstraction
	typedef cub::CtaScan<
		SizeT,
		CTA_THREADS> CtaScanT;

	/**
	 * Shared memory storage layout
	 */
	struct SmemStorage
	{
		union
		{
			typename CtaUpsweepPassT::SmemStorage 		upsweep_storage;
			typename CtaDownsweepPassT::SmemStorage 	downsweep_storage;
			typename CtaSingleTileT::SmemStorage 		single_storage;
			typename CtaSingleTileT1::SmemStorage 		single_storage1;
			typename WarpScanT::SmemStorage				warp_scan_storage;
			typename CtaScanT::SmemStorage				cta_scan_storage;
		};
	};

	// Shared data structures
	__shared__ SmemStorage 								smem_storage;
	__shared__ volatile SizeT							shared_bin_count[SWEEP_RADIX_DIGITS];
	__shared__ unsigned int 							current_bit;
	__shared__ unsigned int 							bits_remaining;
	__shared__ SizeT									num_elements;
	__shared__ SizeT									cta_offset;
	__shared__ volatile unsigned int					enqueue_offset;
	__shared__ unsigned int 							queue_descriptors;

	if (threadIdx.x == 0)
	{
		queue_descriptors = d_queue_counters[(iteration - 1) & 3];

		if (blockIdx.x == 0)
		{
//			printf("%d incoming descriptors\n", queue_descriptors);

			// Reset next work steal counter
			d_steal_counters[(iteration + 1) & 1] = 0;

			// Reset next queue counter
			d_queue_counters[(iteration + 1) & 3] = 0;
		}
	}

	while (true)
	{
		// Retrieve work
		if (threadIdx.x == 0)
		{
			unsigned int descriptor_offset = atomicAdd(d_steal_counters + (iteration & 1), 1);

			num_elements = 0;

			if (descriptor_offset < queue_descriptors)
			{
				BinDescriptor bin 			= d_bins_in[descriptor_offset];
				current_bit 				= bin.current_bit - SWEEP_RADIX_BITS;
				bits_remaining 				= bin.current_bit - low_bit;
				num_elements 				= bin.num_elements;
				cta_offset					= bin.offset;
/*
				if ((descriptor_offset == 0) || ((iteration == 3) && (num_elements > SINGLE_TILE_ITEMS)))
				printf("\tPartition %d stolen by CTA %d: bit(%d) elements(%d) offset(%d)\n",
					descriptor_offset,
					blockIdx.x,
					bin.current_bit,
					bin.num_elements,
					bin.offset);
*/
			}
		}

		__syncthreads();

		if (num_elements == 0)
		{
			return;
		}
/*		else if (num_elements <= SINGLE_TILE_ITEMS1)
		{
			// Sort input tile
			CtaSingleTileT1::Sort(
				smem_storage.single_storage1,
				d_keys_in + cta_offset,
				d_keys_final + cta_offset,
				d_values_in + cta_offset,
				d_values_final + cta_offset,
				low_bit,
				bits_remaining,
				num_elements);
		}
*/		else if (num_elements <= SINGLE_TILE_ITEMS)
		{
			// Sort input tile
			CtaSingleTileT::Sort(
				smem_storage.single_storage,
				d_keys_in + cta_offset,
				d_keys_final + cta_offset,
				d_values_in + cta_offset,
				d_values_final + cta_offset,
				low_bit,
				bits_remaining,
				num_elements);
		}
		else
		{
			SizeT bin_count = 0;
			SizeT bin_prefix = 0;

			// Compute bin-count for each radix digit (valid in tid < RADIX_DIGITS)
			CtaUpsweepPassT::UpsweepPass(
				smem_storage.upsweep_storage,
				d_keys_in + cta_offset,
				current_bit,
				num_elements,
				bin_count);

			// Scan bin counts and output new partitions for next pass
			if (threadIdx.x < SWEEP_RADIX_DIGITS)
			{
				unsigned int my_current_bit = current_bit;

				// Warp prefix sum
				WarpScanT::ExclusiveSum(
					smem_storage.warp_scan_storage,
					bin_count,
					bin_prefix);

				// Agglomerate counts
				shared_bin_count[threadIdx.x] = bin_count;

				#pragma unroll
				for (int BIT = 0; BIT < SWEEP_RADIX_BITS - 1; BIT++)
				{
					const int PEER_STRIDE = 1 << BIT;
					const int MASK = (1 << (BIT + 1)) - 1;

					if ((threadIdx.x & MASK) == 0)
					{
						SizeT next_bin_count = shared_bin_count[threadIdx.x + PEER_STRIDE];
						if (bin_count + next_bin_count < SINGLE_TILE_ITEMS)
						{
							shared_bin_count[threadIdx.x] = bin_count + next_bin_count;
							shared_bin_count[threadIdx.x + PEER_STRIDE] = 0;
							my_current_bit++;
						}
					}

					bin_count = shared_bin_count[threadIdx.x];
				}

				unsigned int active_bins_vote 		= __ballot(bin_count > 0);
				unsigned int thread_mask 			= (1 << threadIdx.x) - 1;
				unsigned int active_bins 			= __popc(active_bins_vote);
				unsigned int active_bins_prefix 	= __popc(active_bins_vote & thread_mask);

				// Increment enqueue offset
				if (threadIdx.x == 0)
				{
					enqueue_offset = atomicAdd(d_queue_counters + (iteration & 3), active_bins);
				}
/*
				if (enqueue_offset == 0) printf("\t\tCta %d, tid %d, bin_count %d, active_bins %d, active_bins_prefix %d\n",
					blockIdx.x,
					threadIdx.x,
					bin_count,
					active_bins,
					active_bins_prefix);
*/
				// Output bin
				if (bin_count > 0)
				{
					BinDescriptor bin(
						cta_offset + bin_prefix,
						bin_count,
						my_current_bit);
/*
					if (enqueue_offset + active_bins_prefix == 0)
					printf("CTA %d, num elements %d, bin %d created partition descriptor %d: bit(%d) elements(%d) offset(%d)\n",
						blockIdx.x,
						num_elements,
						threadIdx.x,
						enqueue_offset + active_bins_prefix,
						bin.current_bit,
						bin.num_elements,
						bin.offset);
*/
					d_bins_out[enqueue_offset + active_bins_prefix] = bin;
				}
			}

			// Distribute keys
			CtaDownsweepPassT::DownsweepPass(
				smem_storage.downsweep_storage,
				bin_prefix,
				d_keys_in + cta_offset,
				d_keys_out + cta_offset,
				d_values_in + cta_offset,
				d_values_out + cta_offset,
				current_bit,
				num_elements);
		}
	}
}


/**
 * Hybrid kernel props
 */
template <
	typename KeyType,
	typename ValueType,
	typename SizeT>
struct HybridKernelProps : cub::KernelProps
{
	// Kernel function type
	typedef void (*KernelFunc)(
		unsigned int*,
		unsigned int*,
		BinDescriptor*,
		BinDescriptor*,
		KeyType*,
		KeyType*,
		KeyType*,
		ValueType*,
		ValueType*,
		ValueType*,
		unsigned int,
		int);

	// Fields
	KernelFunc 					kernel_func;
	cudaSharedMemConfig 		sm_bank_config;

	/**
	 * Initializer
	 */
	template <
		typename CtaHybridPassPolicy,
		typename OpaqueCtaHybridPassPolicy,
		int MIN_CTA_OCCUPANCY>
	cudaError_t Init(const cub::CudaProps &cuda_props)	// CUDA properties for a specific device
	{
		// Initialize fields
		kernel_func 			= HybridKernel<OpaqueCtaHybridPassPolicy, MIN_CTA_OCCUPANCY, SizeT>;
		sm_bank_config 			= CtaHybridPassPolicy::SMEM_CONFIG;

		// Initialize super class
		return cub::KernelProps::Init(
			kernel_func,
			CtaHybridPassPolicy::CTA_THREADS,
			cuda_props);
	}

	/**
	 * Initializer
	 */
	template <typename CtaHybridPassPolicy>
	cudaError_t Init(const cub::CudaProps &cuda_props)	// CUDA properties for a specific device
	{
		return Init<CtaHybridPassPolicy, CtaHybridPassPolicy>(cuda_props);
	}

};


} // namespace radix_sort
} // namespace back40
BACK40_NS_POSTFIX
