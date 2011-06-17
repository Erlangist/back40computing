/******************************************************************************
 * 
 * Copyright 2010-2011 Duane Merrill
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
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 ******************************************************************************/

/******************************************************************************
 * CTA-processing functionality for consecutive reduction upsweep reduction
 * kernels
 ******************************************************************************/

#pragma once

#include <b40c/util/io/modified_load.cuh>
#include <b40c/util/io/modified_store.cuh>
#include <b40c/util/io/load_tile.cuh>

#include <b40c/util/soa_tuple.cuh>
#include <b40c/util/reduction/soa/cooperative_soa_reduction.cuh>

namespace b40c {
namespace consecutive_reduction {
namespace upsweep {


/**
 * Consecutive reduction upsweep reduction CTA
 */
template <typename KernelPolicy>
struct Cta
{
	//---------------------------------------------------------------------
	// Typedefs and constants
	//---------------------------------------------------------------------

	typedef typename KernelPolicy::KeyType 					KeyType;
	typedef typename KernelPolicy::ValueType				ValueType;
	typedef typename KernelPolicy::SizeT 					SizeT;

	typedef typename KernelPolicy::SpinePartialType			SpinePartialType;		// Same as ValueType
	typedef typename KernelPolicy::SpineFlagType			SpineFlagType;

	typedef typename KernelPolicy::SrtsSoaDetails 			SrtsSoaDetails;
	typedef typename KernelPolicy::SoaTuple 				SoaTuple;

	typedef util::Tuple<
		ValueType (*)[KernelPolicy::LOAD_VEC_SIZE],
		SpineFlagType (*)[KernelPolicy::LOAD_VEC_SIZE]> 	DataSoa;


	//---------------------------------------------------------------------
	// Members
	//---------------------------------------------------------------------

	// Operational details for SRTS grid
	SrtsSoaDetails 		srts_soa_details;

	// The spine value-flag tuple value we will accumulate (in raking threads only)
	SoaTuple 			carry;

	// Device pointers
	KeyType 			*d_in_keys;
	ValueType 			*d_in_values;

	SpinePartialType	*d_spine_partials;
	SpineFlagType 		*d_spine_flags;

	//---------------------------------------------------------------------
	// Methods
	//---------------------------------------------------------------------

	/**
	 * Constructor
	 */
	template <typename SmemStorage>
	__device__ __forceinline__ Cta(
		SmemStorage 	&smem_storage,
		KeyType 				*d_in_keys,
		ValueType 				*d_in_values,
		SpinePartialType 		*d_spine_partials,
		SpineFlagType 			*d_spine_flags) :

			srts_soa_details(
				typename SrtsSoaDetails::GridStorageSoa(
					smem_storage.partials_raking_elements,
					smem_storage.flags_raking_elements),
				typename SrtsSoaDetails::WarpscanSoa(
					smem_storage.partials_warpscan,
					smem_storage.flags_warpscan),
				KernelPolicy::SoaTupleIdentity()),
			d_in_keys(d_in_keys),
			d_in_values(d_in_values),
			d_spine_partials(d_spine_partials),
			d_spine_flags(d_spine_flags),
			carry(KernelPolicy::SoaTupleIdentity()) {}


	/**
	 * Process a single, full tile
	 */
	template <bool FIRST_TILE>
	__device__ __forceinline__ void ProcessTile(
		SizeT cta_offset,
		SizeT guarded_elements = KernelPolicy::TILE_ELEMENTS)
	{
		KeyType			keys[KernelPolicy::LOADS_PER_TILE][KernelPolicy::LOAD_VEC_SIZE];
		ValueType		values[KernelPolicy::LOADS_PER_TILE][KernelPolicy::LOAD_VEC_SIZE];
		SpineFlagType	ranks[KernelPolicy::LOADS_PER_TILE][KernelPolicy::LOAD_VEC_SIZE];			// Tile of global scatter offsets

		// Load keys, initializing discontinuity flags in ranks
		util::io::LoadTile<
			KernelPolicy::LOG_LOADS_PER_TILE,
			KernelPolicy::LOG_LOAD_VEC_SIZE,
			KernelPolicy::THREADS,
			KernelPolicy::READ_MODIFIER>::template LoadDiscontinuity<FIRST_TILE>(
				keys,
				ranks,
				d_in_keys + cta_offset,
				guarded_elements);

		// Load values
		util::io::LoadTile<
			KernelPolicy::LOG_LOADS_PER_TILE,
			KernelPolicy::LOG_LOAD_VEC_SIZE,
			KernelPolicy::THREADS,
			KernelPolicy::READ_MODIFIER>::LoadValid(
				values,
				KernelPolicy::Identity(),
				d_in_values + cta_offset,
				guarded_elements);

		// SOA-reduce tile of tuple pairs
		util::reduction::soa::CooperativeSoaTileReduction<
			SrtsSoaDetails,
			KernelPolicy::LOAD_VEC_SIZE,
			KernelPolicy::SoaScanOp>::template ReduceTileWithCarry<true>(	// Maintain carry in thread SrtsSoaDetails::CUMULATIVE_THREAD
				srts_soa_details,
				DataSoa(values, ranks),
				carry);														// Seed with carry

		// Barrier to protect srts_soa_details before next tile
		__syncthreads();
	}


	/**
	 * Stores final reduction to output
	 */
	__device__ __forceinline__ void OutputToSpine()
	{
		// Write output
		if (threadIdx.x == SrtsSoaDetails::CUMULATIVE_THREAD) {

			util::io::ModifiedStore<KernelPolicy::WRITE_MODIFIER>::St(
				carry.t0,
				d_spine_partials + blockIdx.x);

			util::io::ModifiedStore<KernelPolicy::WRITE_MODIFIER>::St(
				carry.t1,
				d_spine_flags + blockIdx.x);
		}
	}


	/**
	 * Process work range of tiles
	 */
	__device__ __forceinline__ void ProcessWorkRange(
		util::CtaWorkLimits<SizeT> &work_limits)
	{
		// Make sure we get a local copy of the cta's offset (work_limits may be in smem)
		SizeT cta_offset = work_limits.offset;

		if (cta_offset < work_limits.guarded_offset) {

			// Process at least one full tile of tile_elements (first tile)
			ProcessTile<true>(cta_offset);
			cta_offset += KernelPolicy::TILE_ELEMENTS;

			while (cta_offset < work_limits.guarded_offset) {
				// Process more full tiles (not first tile)
				ProcessTile<false>(cta_offset);
				cta_offset += KernelPolicy::TILE_ELEMENTS;
			}

			// Clean up last partial tile with guarded-io (not first tile)
			if (work_limits.guarded_elements) {
				ProcessTile<false>(
					cta_offset,
					work_limits.guarded_elements);
			}

		} else {

			// Clean up last partial tile with guarded-io (first tile)
			ProcessTile<true>(
				cta_offset,
				work_limits.guarded_elements);
		}

		// Produce output in spine
		OutputToSpine();
	}
};


} // namespace upsweep
} // namespace consecutive_reduction
} // namespace b40c

