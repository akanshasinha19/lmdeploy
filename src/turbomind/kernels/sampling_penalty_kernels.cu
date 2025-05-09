/*
 * Copyright (c) 2020-2023, NVIDIA CORPORATION.  All rights reserved.
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
 */

#include <assert.h>
#include <float.h>

#include "src/turbomind/kernels/core/array_ops.h"
#include "src/turbomind/kernels/core/common.h"
#include "src/turbomind/kernels/reduce_kernel_utils.cuh"
#include "src/turbomind/kernels/sampling_penalty_kernels.h"

namespace turbomind {

// TODO Add half2 implementation
template<typename T>
__global__ void applyTemperaturePenalty(T*          logits,
                                        const T*    bias,
                                        const float temperature_inverse,
                                        const int   m,
                                        const int   vocab_size,
                                        const int   vocab_size_padd)
{
    const T MAX_T_VAL = getMaxValue<T>();
    for (int index = blockIdx.x * blockDim.x + threadIdx.x; index < m * vocab_size_padd;
         index += blockDim.x * gridDim.x) {
        T bias_val = bias == nullptr ? (T)(0.0f) : bias[index % vocab_size_padd];
        if (index % vocab_size_padd < vocab_size) {
            logits[index] = (logits[index] + bias_val) * (T)temperature_inverse;
        }
        else {
            logits[index] = -MAX_T_VAL;
        }
    }
}

template<>
__global__ void applyTemperaturePenalty(half2*       logits,
                                        const half2* bias,
                                        const float  temperature_inverse,
                                        const int    batch_size,
                                        const int    vocab_size,
                                        const int    vocab_size_padded)
{
    assert(vocab_size % 2 == 0);
    assert(vocab_size_padded % 2 == 0);
    const half2 mask_val = __float2half2_rn(-65504.0f);
    const half2 temp_inv = __float2half2_rn(temperature_inverse);

    const int half_vocab_size        = vocab_size / 2;
    const int half_vocab_size_padded = vocab_size_padded / 2;
    for (int index = blockIdx.x * blockDim.x + threadIdx.x; index < batch_size * half_vocab_size_padded;
         index += blockDim.x * gridDim.x) {
        int   vocab_idx = index % half_vocab_size_padded;
        half2 logit     = vocab_idx < half_vocab_size ? __ldg(&logits[index]) : mask_val;
        if (vocab_idx < half_vocab_size) {
            if (bias != nullptr) {
                logit = __hadd2(logit, bias[vocab_idx]);
            }
            logits[index] = __hmul2(logit, temp_inv);
        }
    }
}

template<typename T>
void invokeApplyTemperaturePenalty(T*           logits,
                                   const T*     bias,
                                   const float  temperature,
                                   const int    batch_size,
                                   const int    vocab_size,
                                   const int    vocab_size_padd,
                                   cudaStream_t stream)
{
    dim3        block(min(vocab_size_padd, 1024));
    dim3        grid(min(batch_size * vocab_size_padd / block.x, 65536));
    const float temperature_inverse = 1.f / (temperature + 1e-6f);
    if (std::is_same<T, half>::value && vocab_size % 2 == 0 && vocab_size_padd % 2 == 0) {
        applyTemperaturePenalty<<<grid, block, 0, stream>>>(reinterpret_cast<half2*>(logits),
                                                            reinterpret_cast<const half2*>(bias),
                                                            temperature_inverse,
                                                            batch_size,
                                                            vocab_size,
                                                            vocab_size_padd);
    }
    else {
        applyTemperaturePenalty<T>
            <<<grid, block, 0, stream>>>(logits, bias, temperature_inverse, batch_size, vocab_size, vocab_size_padd);
    }
}

#define INISTANTIATE_INVOKE_APPLY_TEMPERATURE_PENALTY(T)                                                               \
    template void invokeApplyTemperaturePenalty(T*           logits,                                                   \
                                                const T*     bias,                                                     \
                                                const float  temperature,                                              \
                                                const int    batch_size,                                               \
                                                const int    vocab_size,                                               \
                                                const int    vocab_size_padd,                                          \
                                                cudaStream_t stream);

#ifdef ENABLE_FP32
INISTANTIATE_INVOKE_APPLY_TEMPERATURE_PENALTY(float);
#endif
INISTANTIATE_INVOKE_APPLY_TEMPERATURE_PENALTY(half);
#ifdef ENABLE_BF16
INISTANTIATE_INVOKE_APPLY_TEMPERATURE_PENALTY(__nv_bfloat16);
#endif

template<typename T>
__global__ void batchApplyTemperaturePenalty(T*           logits,
                                             const T*     bias,
                                             const float* temperatures,
                                             const int    batch_size,
                                             const int    vocab_size,
                                             const int    vocab_size_padd)
{
    const T                 MAX_T_VAL = getMaxValue<T>();
    extern __shared__ float inv_temperatures[];
    if (threadIdx.x < batch_size) {
        inv_temperatures[threadIdx.x] = 1.0f / (temperatures[threadIdx.x] + 1e-6f);
    }
    __syncthreads();

    for (int index = blockIdx.x * blockDim.x + threadIdx.x; index < batch_size * vocab_size_padd;
         index += blockDim.x * gridDim.x) {
        int batch_idx = index / vocab_size_padd;
        int vocab_idx = index % vocab_size_padd;
        T   logit     = (vocab_idx < vocab_size) ? logits[index] : (T)-MAX_T_VAL;
        if (vocab_idx < vocab_size) {
            if (bias != nullptr) {
                logit = (float)logit + (float)bias[vocab_idx];
            }
            logit = (float)logit * inv_temperatures[batch_idx];
        }
        logits[index] = logit;
    }
}

__global__ void batchApplyTemperaturePenalty_h2(half2*       logits,
                                                const half2* bias,
                                                const float* temperatures,
                                                const int    batch_size,
                                                const int    vocab_size,
                                                const int    vocab_size_padded)
{
    assert(vocab_size % 2 == 0);
    assert(vocab_size_padded % 2 == 0);
    extern __shared__ half2 h2_inv_temperatures[];
    if (threadIdx.x < batch_size) {
        h2_inv_temperatures[threadIdx.x] = __float2half2_rn(1.f / (temperatures[threadIdx.x] + 1e-6f));
    }
    __syncthreads();

    const half2 mask_val               = __float2half2_rn(-65504.0f);
    const int   half_vocab_size        = vocab_size / 2;
    const int   half_vocab_size_padded = vocab_size_padded / 2;
    for (int index = blockIdx.x * blockDim.x + threadIdx.x; index < batch_size * half_vocab_size_padded;
         index += blockDim.x * gridDim.x) {
        int   batch_idx = index / half_vocab_size_padded;
        int   vocab_idx = index % half_vocab_size_padded;
        half2 logit     = vocab_idx < half_vocab_size ? __ldg(&logits[index]) : mask_val;
        if (vocab_idx < half_vocab_size) {
            if (bias != nullptr) {
                logit = __hadd2(logit, bias[vocab_idx]);
            }
            logits[index] = __hmul2(logit, h2_inv_temperatures[batch_idx]);
        }
    }
}

template<typename T>
void invokeBatchApplyTemperaturePenalty(T*           logits,
                                        const T*     bias,
                                        const float* temperatures,
                                        const int    batch_size,
                                        const int    vocab_size,
                                        const int    vocab_size_padd,
                                        cudaStream_t stream)
{
    dim3 block(min(vocab_size_padd, 1024));
    dim3 grid(min(batch_size * vocab_size_padd / block.x, 65536));
    if (std::is_same<T, half>::value && vocab_size % 2 == 0 && vocab_size_padd % 2 == 0) {
        size_t smem_size = sizeof(half2) * batch_size;
        batchApplyTemperaturePenalty_h2<<<grid, block, smem_size, stream>>>(reinterpret_cast<half2*>(logits),
                                                                            reinterpret_cast<const half2*>(bias),
                                                                            temperatures,
                                                                            batch_size,
                                                                            vocab_size,
                                                                            vocab_size_padd);
    }
    else {
        size_t smem_size = sizeof(float) * batch_size;
        batchApplyTemperaturePenalty<T>
            <<<grid, block, smem_size, stream>>>(logits, bias, temperatures, batch_size, vocab_size, vocab_size_padd);
    }
}

#define INISTANTIATE_INVOKE_BATCH_APPLY_TEMPERATURE_PENALTY(T)                                                         \
    template void invokeBatchApplyTemperaturePenalty(T*           logits,                                              \
                                                     const T*     bias,                                                \
                                                     const float* temperatures,                                        \
                                                     const int    batch_size,                                          \
                                                     const int    vocab_size,                                          \
                                                     const int    vocab_size_padd,                                     \
                                                     cudaStream_t stream);

#ifdef ENABLE_FP32
INISTANTIATE_INVOKE_BATCH_APPLY_TEMPERATURE_PENALTY(float);
#endif
INISTANTIATE_INVOKE_BATCH_APPLY_TEMPERATURE_PENALTY(half);
#ifdef ENABLE_BF16
INISTANTIATE_INVOKE_BATCH_APPLY_TEMPERATURE_PENALTY(__nv_bfloat16);
#endif

template<typename T, int vec_size>
__global__ void batchApplyTemperaturePenalty_v2(T*           logits,
                                                const T*     bias,
                                                const float* temperatures,
                                                const int    batch_size,
                                                const int    vocab_size,
                                                const int    vocab_size_padded)
{
    const int vi = blockIdx.x * blockDim.x + threadIdx.x;
    const int bi = blockIdx.y;

    __shared__ float shared_scale;

    if (threadIdx.x == 0) {
        shared_scale = fdividef(1.f, temperatures[bi] + 1e-6f);
    }

    __syncthreads();

    const float scale = shared_scale;

    logits += (size_t)bi * vocab_size_padded;

    const int step = gridDim.x * blockDim.x * vec_size;

    for (int i = vi * vec_size; i < vocab_size_padded; i += step) {
        Array<T, vec_size> vec;
        // load
        if constexpr (sizeof(vec) >= sizeof(uint)) {
            Load(vec, logits + i);
        }
        else {
            PRAGMA_UNROLL
            for (int j = 0; j < vec_size; ++j) {
                vec[j] = logits[i + j];
            }
        }

        // process
        PRAGMA_UNROLL
        for (int c = 0; c < vec_size; ++c) {
            if (i + c < vocab_size) {
                vec[c] = (float)vec[c] * scale;
            }
            else {
                vec[c] = -getMaxValue<T>();
            }
        }

        // store
        if constexpr (sizeof(vec) >= sizeof(uint)) {
            Store(logits + i, vec);
        }
        else {
            PRAGMA_UNROLL
            for (int j = 0; j < vec_size; ++j) {
                logits[i + j] = vec[j];
            }
        }
    }
}

template<typename T>
void invokeBatchApplyTemperaturePenalty_v2(T*           logits,
                                           const T*     bias,
                                           const float* temperatures,
                                           const int    batch_size,
                                           const int    vocab_size,
                                           const int    vocab_size_padded,
                                           cudaStream_t stream)
{

    auto invoke = [&](auto vec_size) {
        constexpr int threads        = 256;
        const int     blocks_per_tok = (vocab_size_padded + threads * vec_size - 1) / (threads * vec_size);
        const dim3    blocks(blocks_per_tok, batch_size);
        batchApplyTemperaturePenalty_v2<T, vec_size.value><<<blocks, threads, 0, stream>>>(  //
            logits,
            bias,
            temperatures,
            batch_size,
            vocab_size,
            vocab_size_padded);
    };

    if (vocab_size_padded % 4 == 0) {
        invoke(std::integral_constant<int, 4>{});
    }
    else if (vocab_size_padded % 2 == 0) {
        invoke(std::integral_constant<int, 2>{});
    }
    else {
        invoke(std::integral_constant<int, 1>{});
    }
}

#define INSTANTIATE_INVOKE_BATCH_APPLY_TEMPERATURE_PENALTY_V2(T)                                                       \
    template void invokeBatchApplyTemperaturePenalty_v2(T*           logits,                                           \
                                                        const T*     bias,                                             \
                                                        const float* temperatures,                                     \
                                                        const int    batch_size,                                       \
                                                        const int    vocab_size,                                       \
                                                        const int    vocab_size_padded,                                \
                                                        cudaStream_t stream);

#ifdef ENABLE_FP32
INSTANTIATE_INVOKE_BATCH_APPLY_TEMPERATURE_PENALTY_V2(float);
#endif
INSTANTIATE_INVOKE_BATCH_APPLY_TEMPERATURE_PENALTY_V2(half);
#ifdef ENABLE_BF16
INSTANTIATE_INVOKE_BATCH_APPLY_TEMPERATURE_PENALTY_V2(__nv_bfloat16);
#endif

template<typename T, RepetitionPenaltyType penalty_type>
__global__ void applyRepetitionPenalty(T*          logits,
                                       const float penalty,
                                       const int*  start_ids,
                                       int*        output_ids,
                                       const int   batch_size,
                                       const int   local_batch_size,
                                       const int   vocab_size,
                                       const int   vocab_size_padd,
                                       const int*  input_lengths,
                                       const int   max_input_len,
                                       const int   step)
{
    extern __shared__ float penalty_logits[];
    int*                    penalty_indices = (int*)(penalty_logits + step);

    logits                 = logits + blockIdx.x * vocab_size_padd;
    const int input_length = input_lengths != nullptr ? input_lengths[blockIdx.x] : max_input_len;
    for (int index = threadIdx.x; index < step; index += blockDim.x) {

        if (index >= input_length && index < max_input_len) {
            continue;
        }

        // output_ids shape: (input_len + output_len, batch_size)
        int penalty_index = output_ids[index * batch_size + blockIdx.x];
        if (penalty_index >= vocab_size) {
            continue;
        }
        penalty_indices[index] = penalty_index;
        float logit            = (float)logits[penalty_index];
        if (penalty_type == RepetitionPenaltyType::Additive) {
            penalty_logits[index] = logit - penalty;
        }
        else if (penalty_type == RepetitionPenaltyType::Multiplicative) {
            penalty_logits[index] = logit < 0.0f ? logit * penalty : logit / penalty;
        }
        else if (penalty_type == RepetitionPenaltyType::None) {
            penalty_logits[index] = logit;
        }
        else {
            // Unsupported type
            assert(false);
        }
    }

    if (blockDim.x > 32) {
        __syncthreads();
    }

    for (int index = threadIdx.x; index < step; index += blockDim.x) {

        if (index >= input_length && index < max_input_len) {
            continue;
        }

        // output_ids shape: (input_len + output_len, batch_size)
        if (penalty_indices[index] >= vocab_size) {
            continue;
        }
        logits[penalty_indices[index]] = penalty_logits[index];
    }
}

template<typename T>
void invokeApplyRepetitionPenalty(T*                          logits,
                                  const float                 penalty,
                                  const int*                  start_ids,
                                  int*                        output_ids,
                                  const int                   batch_size,
                                  const int                   local_batch_size,
                                  const int                   vocab_size,
                                  const int                   vocab_size_padd,
                                  const int*                  input_lengths,
                                  const int                   max_input_len,
                                  const int                   step,
                                  const RepetitionPenaltyType penalty_type,
                                  cudaStream_t                stream)
{
    dim3   block(min(step, 1024));
    dim3   grid(local_batch_size);
    size_t smem_size = step * (sizeof(float) + sizeof(int));

    if (penalty_type == RepetitionPenaltyType::Additive) {
        applyRepetitionPenalty<T, RepetitionPenaltyType::Additive><<<grid, block, smem_size, stream>>>(logits,
                                                                                                       penalty,
                                                                                                       start_ids,
                                                                                                       output_ids,
                                                                                                       batch_size,
                                                                                                       local_batch_size,
                                                                                                       vocab_size,
                                                                                                       vocab_size_padd,
                                                                                                       input_lengths,
                                                                                                       max_input_len,
                                                                                                       step);
    }
    else if (penalty_type == RepetitionPenaltyType::Multiplicative) {
        applyRepetitionPenalty<T, RepetitionPenaltyType::Multiplicative>
            <<<grid, block, smem_size, stream>>>(logits,
                                                 penalty,
                                                 start_ids,
                                                 output_ids,
                                                 batch_size,
                                                 local_batch_size,
                                                 vocab_size,
                                                 vocab_size_padd,
                                                 input_lengths,
                                                 max_input_len,
                                                 step);
    }
    else if (penalty_type == RepetitionPenaltyType::None) {
        // do nothing
    }
}

#define INISTANTIATE_INVOKE_APPLY_REPETITION_PENALTY(T)                                                                \
    template void invokeApplyRepetitionPenalty(T*                          logits,                                     \
                                               const float                 penalty,                                    \
                                               const int*                  start_ids,                                  \
                                               int*                        output_ids,                                 \
                                               const int                   batch_size,                                 \
                                               const int                   local_batch_size,                           \
                                               const int                   vocab_size,                                 \
                                               const int                   vocab_size_padd,                            \
                                               const int*                  input_lengths,                              \
                                               const int                   max_input_len,                              \
                                               const int                   step,                                       \
                                               const RepetitionPenaltyType penalty_type,                               \
                                               cudaStream_t                stream);

#ifdef ENABLE_FP32
INISTANTIATE_INVOKE_APPLY_REPETITION_PENALTY(float);
#endif
INISTANTIATE_INVOKE_APPLY_REPETITION_PENALTY(half);
#ifdef ENABLE_BF16
INISTANTIATE_INVOKE_APPLY_REPETITION_PENALTY(__nv_bfloat16);
#endif

template<typename T, RepetitionPenaltyType penalty_type>
__global__ void batchApplyRepetitionPenalty(T*           logits,
                                            const float* penalties,
                                            int*         penalty_workspace,
                                            const int*   output_ids,
                                            const int    batch_size,
                                            const int    vocab_size,
                                            const int*   input_lengths,
                                            const int    max_input_length,
                                            const int    step)
{
    const int   batch_idx    = blockIdx.x;
    const float penalty      = penalties[batch_idx];
    const int   input_length = input_lengths != nullptr ? input_lengths[batch_idx] : max_input_length;

    penalty_workspace += batch_idx * step * 2;
    float* penalty_logits  = (float*)penalty_workspace;
    int*   penalty_indices = (int*)(penalty_workspace + step);

    logits += batch_idx * vocab_size;

    // Phase 1. Find indices to penalize and keep the penalized values.
    // A vocab id can appear multiple times but should be penalized once.
    for (int index = threadIdx.x; index < step; index += blockDim.x) {
        // Skip the padding tokens in input sequences.
        if (index >= input_length && index < max_input_length) {
            continue;
        }
        // output_ids shape: (input_len + output_len, batch_size)
        int penalty_index = output_ids[index * batch_size + batch_idx];
        assert(penalty_index < vocab_size);
        penalty_indices[index] = penalty_index;
        float logit            = (float)logits[penalty_index];
        if (penalty_type == RepetitionPenaltyType::Additive) {
            penalty_logits[index] = logit - penalty;
        }
        else if (penalty_type == RepetitionPenaltyType::Multiplicative) {
            penalty_logits[index] = logit < 0.0f ? logit * penalty : logit / penalty;
        }
        else if (penalty_type == RepetitionPenaltyType::None) {
            penalty_logits[index] = logit;
        }
        else {
            // Unsupported type
            assert(false);
        }
    }

    __syncthreads();

    // Phase 2. Replace a logit value by the penalized one.
    for (int index = threadIdx.x; index < step; index += blockDim.x) {
        // Skip the padding tokens in input sequences.
        if (index >= input_length && index < max_input_length) {
            continue;
        }
        logits[penalty_indices[index]] = penalty_logits[index];
    }
}

template<typename T>
void invokeBatchApplyRepetitionPenalty(T*                    logits,
                                       const float*          penalties,
                                       int*                  penalty_workspace,
                                       const int*            output_ids,
                                       const int             batch_size,
                                       const int             local_batch_size,
                                       const int             vocab_size,
                                       const int*            input_lengths,
                                       const int             max_input_length,
                                       const int             step,
                                       RepetitionPenaltyType penalty_type,
                                       cudaStream_t          stream)
{
    // Inputs
    //   logits [local_batch_size, vocab_size] : logit values.
    //   penalties [local_batch_size] : repetition penalty factors.
    //   output_ids [step, batch_size] : output token ids (with offset ite * local_batch_size).
    //   input_lengths [local_batch_size], input lengths (optional).
    //      Padding tokens at [input_length, max_input_length) of input will not be penalized.
    dim3 block(min(step, 1024));
    dim3 grid(local_batch_size);
    if (penalty_type == RepetitionPenaltyType::Additive) {
        batchApplyRepetitionPenalty<T, RepetitionPenaltyType::Additive><<<grid, block, 0, stream>>>(logits,
                                                                                                    penalties,
                                                                                                    penalty_workspace,
                                                                                                    output_ids,
                                                                                                    batch_size,
                                                                                                    vocab_size,
                                                                                                    input_lengths,
                                                                                                    max_input_length,
                                                                                                    step);
    }
    else if (penalty_type == RepetitionPenaltyType::Multiplicative) {
        batchApplyRepetitionPenalty<T, RepetitionPenaltyType::Multiplicative>
            <<<grid, block, 0, stream>>>(logits,
                                         penalties,
                                         penalty_workspace,
                                         output_ids,
                                         batch_size,
                                         vocab_size,
                                         input_lengths,
                                         max_input_length,
                                         step);
    }
    else if (penalty_type == RepetitionPenaltyType::None) {
        // do nothing
    }
}

#define INSTANTIATE_INVOKE_BATCH_APPLY_REPETITION_PENALTY(T)                                                           \
    template void invokeBatchApplyRepetitionPenalty(T*                    logits,                                      \
                                                    const float*          penalties,                                   \
                                                    int*                  penalty_workspace,                           \
                                                    const int*            output_ids,                                  \
                                                    const int             batch_size,                                  \
                                                    const int             local_batch_size,                            \
                                                    const int             vocab_size,                                  \
                                                    const int*            input_lengths,                               \
                                                    const int             max_input_length,                            \
                                                    const int             step,                                        \
                                                    RepetitionPenaltyType penalty_type,                                \
                                                    cudaStream_t          stream);

#ifdef ENABLE_FP32
INSTANTIATE_INVOKE_BATCH_APPLY_REPETITION_PENALTY(float);
#endif
INSTANTIATE_INVOKE_BATCH_APPLY_REPETITION_PENALTY(half);
#ifdef ENABLE_BF16
INSTANTIATE_INVOKE_BATCH_APPLY_REPETITION_PENALTY(__nv_bfloat16);
#endif

template<typename T>
__global__ void batchApplyMinLengthPenalty(T* __restrict__ logits,
                                           const int* __restrict__ min_lengths,
                                           const int* __restrict__ sequence_lengths,
                                           const int vocab_size_padded,
                                           const int batch_size,
                                           const int* __restrict__ end_ids,
                                           const int end_ids_size)
{
    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    int bid = tid / end_ids_size;
    int eid = tid % end_ids_size;
    if (bid < batch_size) {
        int end_id = end_ids[bid * end_ids_size + eid];
        if (end_id > 0 && sequence_lengths[bid] + 1 < min_lengths[bid]) {
            T mask_val                               = -getMaxValue<T>();
            logits[bid * vocab_size_padded + end_id] = mask_val;
        }
    }
}

template<typename T>
void invokeMinLengthPenalty(T*           logits,
                            const int*   min_lengths,
                            const int*   sequnece_lengths,
                            const int    vocab_size_padded,
                            const int    batch_size,
                            const int*   end_ids,
                            const int    end_ids_size,
                            cudaStream_t stream)
{
    const dim3 block(std::min(batch_size * end_ids_size, 1024));
    const dim3 grid((batch_size * end_ids_size + block.x - 1) / block.x);
    batchApplyMinLengthPenalty<<<block, grid, 0, stream>>>(
        logits, min_lengths, sequnece_lengths, vocab_size_padded, batch_size, end_ids, end_ids_size);
}

#define INSTANTIATE_INVOKE_MIN_LENGTH_PENALTY(T)                                                                       \
    template void invokeMinLengthPenalty(T*           logits,                                                          \
                                         const int*   min_lengths,                                                     \
                                         const int*   sequnece_lengths,                                                \
                                         const int    vocab_size_padded,                                               \
                                         const int    batch_size,                                                      \
                                         const int*   end_ids,                                                         \
                                         const int    end_ids_size,                                                    \
                                         cudaStream_t stream);

#ifdef ENABLE_FP32
INSTANTIATE_INVOKE_MIN_LENGTH_PENALTY(float);
#endif
INSTANTIATE_INVOKE_MIN_LENGTH_PENALTY(half);
#ifdef ENABLE_BF16
INSTANTIATE_INVOKE_MIN_LENGTH_PENALTY(__nv_bfloat16);
#endif

}  // namespace turbomind
