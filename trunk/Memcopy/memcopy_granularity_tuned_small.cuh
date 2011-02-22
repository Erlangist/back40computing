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
 * Default (i.e., small-problem) "granularity tuning types" for memcopy
 ******************************************************************************/

#pragma once

#include "b40c_cuda_properties.cuh"
#include "b40c_kernel_data_movement.cuh"
#include "memcopy_api_granularity.cuh"

namespace b40c {
namespace memcopy {
namespace small_problem_tuning {

/**
 * Enumeration of architecture-families that we have tuned for
 */
enum Family
{
	SM20 	= 200,
	SM13	= 130,
	SM10	= 100
};


/**
 * Classifies a given CUDA_ARCH into an architecture-family
 */
template <int CUDA_ARCH>
struct FamilyClassifier
{
	static const Family FAMILY =	(CUDA_ARCH < SM13) ? 	SM10 :
									(CUDA_ARCH < SM20) ? 	SM13 :
															SM20;
};


/**
 * Granularity parameterization type
 *
 * We can tune this type per SM-architecture, per problem type.
 */
template <int CUDA_ARCH>
struct TunedConfig : TunedConfig<FamilyClassifier<CUDA_ARCH>::FAMILY> {};



//-----------------------------------------------------------------------------
// SM2.0 default granularity parameterization type
//-----------------------------------------------------------------------------

template <>
struct TunedConfig<SM20>
	: MemcopyConfig<
		unsigned long long,		// Data type					Use int64s as primary movement type
		8,						// CTA_OCCUPANCY: 				8 CTAs/SM
		5,						// LOG_THREADS: 				128 threads/CTA
		1,						// LOG_LOAD_VEC_SIZE: 			vec-4
		1,						// LOG_LOADS_PER_TILE: 			4 loads
		CG,						// CACHE_MODIFIER: 				CG (cache global only)
		false,					// WORK_STEALING: 				Equal-shares load-balancing
		7						// LOG_SCHEDULE_GRANULARITY:	128 items
	> {};



//-----------------------------------------------------------------------------
// SM1.3 default granularity parameterization type
//-----------------------------------------------------------------------------

template <>
struct TunedConfig<SM13>
	: MemcopyConfig<
		unsigned char,			// Data type
		8,						// CTA_OCCUPANCY: 				8 CTAs/SM
		6,						// LOG_THREADS: 				128 threads/CTA
		2,						// LOG_LOAD_VEC_SIZE: 			vec-4
		2,						// LOG_LOADS_PER_TILE: 			4 loads
		NONE,					// CACHE_MODIFIER: 				CA (cache all levels)
		false,					// WORK_STEALING: 				Equal-shares load-balancing
		10						// LOG_SCHEDULE_GRANULARITY:	2048 items
	> {};



//-----------------------------------------------------------------------------
// SM1.0 default granularity parameterization type
//-----------------------------------------------------------------------------

template <>
struct TunedConfig<SM10>
	: MemcopyConfig<
		unsigned char,			// Data type
		8,						// CTA_OCCUPANCY: 				8 CTAs/SM
		6,						// LOG_THREADS: 				128 threads/CTA
		2,						// LOG_LOAD_VEC_SIZE: 			vec-4
		2,						// LOG_LOADS_PER_TILE: 			4 loads
		NONE,					// CACHE_MODIFIER: 				CA (cache all levels)
		false,					// WORK_STEALING: 				Equal-shares load-balancing
		10						// LOG_SCHEDULE_GRANULARITY:	2048 items
	> {};





}// namespace small_problem_tuning
}// namespace memcopy
}// namespace b40c