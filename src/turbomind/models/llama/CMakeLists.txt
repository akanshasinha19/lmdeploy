# Copyright (c) OpenMMLab. All rights reserved.

cmake_minimum_required(VERSION 3.8)


find_package(CUDAToolkit REQUIRED)

add_library(Llama STATIC
        LlamaV2.cc
        LlamaBatch.cc
        LlamaLinear.cu
        BlockManager.cc
        BlockTrie.cc
        SequenceManager.cc
        LlamaWeight.cc
        LlamaDecoderLayerWeight.cc
        LlamaFfnLayer.cc
        moe_ffn_layer.cc
        unified_decoder.cc
        unified_attention_layer.cc
        llama_kernels.cu
        llama_decoder_kernels.cu
        llama_utils.cu
        mla_utils.cu)
set_property(TARGET Llama PROPERTY POSITION_INDEPENDENT_CODE  ON)
set_property(TARGET Llama PROPERTY CUDA_RESOLVE_DEVICE_SYMBOLS  ON)
target_link_libraries(Llama PUBLIC CUDA::cudart
        engine
        gemm2
        rms_norm
        cublasMMWrapper
        DynamicDecodeLayer
        activation_kernels
        attention
        decoding_kernels
        unfused_attention_kernels
        gpt_kernels
        tensor
        memory_utils
        cuda_utils
        logger
        anomaly_handler)


add_executable(llama_gemm llama_gemm.cc)
target_link_libraries(llama_gemm PUBLIC CUDA::cudart gpt_gemm_func memory_utils cuda_utils logger)

install(TARGETS llama_gemm DESTINATION ${CMAKE_SOURCE_DIR}/lmdeploy/bin)

# find_package(Catch2 3 QUIET)
# if (Catch2_FOUND)
#         add_executable(test_cache_manager test_cache_manager.cc)
#         target_link_libraries(test_cache_manager PRIVATE Llama Catch2::Catch2WithMain)
# endif ()
