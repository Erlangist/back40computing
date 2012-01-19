/******************************************************************************
 * 
 * Copyright 2010-2012 Duane Merrill
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
 * Thanks!
 * 
 ******************************************************************************/

/******************************************************************************
 * Operational details for threads working in an SRTS grid
 ******************************************************************************/

#pragma once

#include <b40c/util/cuda_properties.cuh>
#include <b40c/util/basic_utils.cuh>

namespace b40c {
namespace util {


/**
 * Operational details for threads working in an SRTS grid
 */
template <
	typename RakingGrid,
	typename SecondaryRakingGrid = typename RakingGrid::SecondaryGrid>
struct SrtsDetails;


/**
 * Operational details for threads working in an SRTS grid (specialized for one-level SRTS grid)
 */
template <typename RakingGrid>
struct SrtsDetails<RakingGrid, NullType> : RakingGrid
{
	enum {
		QUEUE_RSVN_THREAD 	= 0,
		CUMULATIVE_THREAD 	= RakingGrid::RAKING_THREADS - 1,
		WARP_THREADS 		= B40C_WARP_THREADS(SrtsSoaDetails::CUDA_ARCH)
	};

	typedef typename RakingGrid::T T;													// Partial type
	typedef typename RakingGrid::WarpscanT (*WarpscanStorage)[WARP_THREADS];			// Warpscan storage type
	typedef NullType SecondarySrtsDetails;											// Type of next-level grid SRTS details


	/**
	 * Smem pool backing SRTS grid lanes
	 */
	T *smem_pool;

	/**
	 * Warpscan storage
	 */
	WarpscanStorage warpscan;

	/**
	 * The location in the smem grid where the calling thread can insert/extract
	 * its partial for raking reduction/scan into the first lane.
	 */
	typename RakingGrid::LanePartial lane_partial;

	/**
	 * Returns the location in the smem grid where the calling thread can begin serial
	 * raking/scanning
	 */
	typename RakingGrid::RakingSegment raking_segment;

	/**
	 * Constructor
	 */
	__device__ __forceinline__ SrtsDetails(
		T *smem_pool) :
			smem_pool(smem_pool),
			lane_partial(RakingGrid::MyLanePartial(smem_pool))						// set lane partial pointer
	{
		if (threadIdx.x < RakingGrid::RAKING_THREADS) {

			// Set raking segment pointer
			raking_segment = RakingGrid::MyRakingSegment(smem_pool);
		}
	}


	/**
	 * Constructor
	 */
	__device__ __forceinline__ SrtsDetails(
		T *smem_pool,
		WarpscanStorage warpscan) :
			smem_pool(smem_pool),
			warpscan(warpscan),
			lane_partial(RakingGrid::MyLanePartial(smem_pool))						// set lane partial pointer
	{
		if (threadIdx.x < RakingGrid::RAKING_THREADS) {

			// Set raking segment pointer
			raking_segment = RakingGrid::MyRakingSegment(smem_pool);
		}
	}


	/**
	 * Constructor
	 */
	__device__ __forceinline__ SrtsDetails(
		T *smem_pool,
		WarpscanStorage warpscan,
		T warpscan_identity) :
			smem_pool(smem_pool),
			warpscan(warpscan),
			lane_partial(RakingGrid::MyLanePartial(smem_pool))						// set lane partial pointer
	{
		if (threadIdx.x < RakingGrid::RAKING_THREADS) {

			// Initialize first half of warpscan storage to identity
			warpscan[0][threadIdx.x] = warpscan_identity;

			// Set raking segment pointer
			raking_segment = RakingGrid::MyRakingSegment(smem_pool);
		}
	}


	/**
	 * Return the cumulative partial left in the final warpscan cell
	 */
	__device__ __forceinline__ T CumulativePartial() const
	{
		return warpscan[1][CUMULATIVE_THREAD];
	}


	/**
	 * Return the queue reservation in the first warpscan cell
	 */
	__device__ __forceinline__ T QueueReservation() const
	{
		return warpscan[1][QUEUE_RSVN_THREAD];
	}


	/**
	 *
	 */
	__device__ __forceinline__ T* SmemPool()
	{
		return smem_pool;
	}
};


/**
 * Operational details for threads working in a hierarchical SRTS grid
 */
template <
	typename RakingGrid,
	typename SecondaryRakingGrid>
struct SrtsDetails : RakingGrid
{
	enum {
		CUMULATIVE_THREAD 	= RakingGrid::RAKING_THREADS - 1,
		WARP_THREADS 		= B40C_WARP_THREADS(SrtsSoaDetails::CUDA_ARCH)
	};

	typedef typename RakingGrid::T T;													// Partial type
	typedef typename RakingGrid::WarpscanT (*WarpscanStorage)[WARP_THREADS];			// Warpscan storage type
	typedef SrtsDetails<SecondaryRakingGrid> SecondarySrtsDetails;					// Type of next-level grid SRTS details


	/**
	 * The location in the smem grid where the calling thread can insert/extract
	 * its partial for raking reduction/scan into the first lane.
	 */
	typename RakingGrid::LanePartial lane_partial;

	/**
	 * Returns the location in the smem grid where the calling thread can begin serial
	 * raking/scanning
	 */
	typename RakingGrid::RakingSegment raking_segment;

	/**
	 * Secondary-level grid details
	 */
	SecondarySrtsDetails secondary_details;

	/**
	 * Constructor
	 */
	__device__ __forceinline__ SrtsDetails(
		T *smem_pool) :
			lane_partial(RakingGrid::MyLanePartial(smem_pool)),							// set lane partial pointer
			secondary_details(
				smem_pool + RakingGrid::RAKING_ELEMENTS)
	{
		if (threadIdx.x < RakingGrid::RAKING_THREADS) {
			// Set raking segment pointer
			raking_segment = RakingGrid::MyRakingSegment(smem_pool);
		}
	}

	/**
	 * Constructor
	 */
	__device__ __forceinline__ SrtsDetails(
		T *smem_pool,
		WarpscanStorage warpscan) :
			lane_partial(RakingGrid::MyLanePartial(smem_pool)),							// set lane partial pointer
			secondary_details(
				smem_pool + RakingGrid::RAKING_ELEMENTS,
				warpscan)
	{
		if (threadIdx.x < RakingGrid::RAKING_THREADS) {
			// Set raking segment pointer
			raking_segment = RakingGrid::MyRakingSegment(smem_pool);
		}
	}


	/**
	 * Constructor
	 */
	__device__ __forceinline__ SrtsDetails(
		T *smem_pool,
		WarpscanStorage warpscan,
		T warpscan_identity) :
			lane_partial(RakingGrid::MyLanePartial(smem_pool)),							// set lane partial pointer
			secondary_details(
				smem_pool + RakingGrid::RAKING_ELEMENTS,
				warpscan,
				warpscan_identity)
	{
		if (threadIdx.x < RakingGrid::RAKING_THREADS) {
			// Set raking segment pointer
			raking_segment = RakingGrid::MyRakingSegment(smem_pool);
		}
	}


	/**
	 * Return the cumulative partial left in the final warpscan cell
	 */
	__device__ __forceinline__ T CumulativePartial() const
	{
		return secondary_details.CumulativePartial();
	}

	/**
	 * Return the queue reservation in the first warpscan cell
	 */
	__device__ __forceinline__ T QueueReservation() const
	{
		return secondary_details.QueueReservation();
	}

	/**
	 *
	 */
	__device__ __forceinline__ T* SmemPool()
	{
		return secondary_details.SmemPool();
	}
};





} // namespace util
} // namespace b40c

