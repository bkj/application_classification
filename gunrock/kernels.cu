#include <iostream>
#include <assert.h>
#include "main.h"
#include <cub/cub.cuh>

#define THREAD 1024

// --
// Kernels

// __global__ FloatT norm_1(int ATtr, FloatT * vec1) {
//   FloatT sum = 0.0;
//   for (int i = 0; i < ATtr; i ++) {
//     sum += (vec1[i] * vec1[i]);
//   }
//   return sqrt(sum);
// }

__device__ FloatT d_norm_2(int ATtr, FloatT * vec1, FloatT * vec2) {
  FloatT sum = 0.0;
  for (int i = 0; i < ATtr; i ++) {
    sum += (vec1[i] - vec2[i]) * (vec1[i] - vec2[i]);
  }
  return sqrt(sum);
}

__global__ void __transpose(FloatT *d_xt, FloatT *d_x, IntT num_rows, IntT num_cols) {
  IntT offset = threadIdx.x + blockDim.x * blockIdx.x;
  if(offset < num_rows * num_cols) {
    IntT row = offset / num_cols;
    IntT col = offset % num_cols;
    d_xt[col * num_rows + row] = d_x[offset];
  }
}

__global__ void __rowSubExp(FloatT* d_x, IntT num_rows, IntT num_cols, FloatT* c) {
  IntT offset = threadIdx.x + blockDim.x * blockIdx.x;
  if(offset < num_rows * num_cols) {
    IntT row = offset / num_cols;
    d_x[offset] = exp(d_x[offset] - c[row]);
  }
}

__global__ void __rowSubLog(FloatT* d_x, IntT num_rows, IntT num_cols, FloatT* c) {
  IntT offset = threadIdx.x + blockDim.x * blockIdx.x;
  if(offset < num_rows * num_cols) {
    IntT row = offset / num_cols;
    d_x[offset] = log(d_x[offset]) - log(c[row]);
  }
}


void d_rowmax(FloatT * d_out, FloatT * d_in, IntT num_rows, IntT num_cols) {
  void *d_temp_storage = NULL;
  size_t temp_storage_bytes = 0;

  // Compute offsets of matrix
  IntT h_offsets[num_rows + 1];
  IntT *d_offsets;
  for(IntT i = 0; i < num_rows + 1; i++) {
    h_offsets[i] = i * num_cols;
  }
  cudaMalloc((void**)&d_offsets, (num_rows + 1) * sizeof(IntT));
  cudaMemcpy(d_offsets, h_offsets, (num_rows + 1) * sizeof(IntT), cudaMemcpyHostToDevice);

  // Max over rows
  cub::DeviceSegmentedReduce::Max(
    d_temp_storage,
    temp_storage_bytes,
    d_in,
    d_out,
    num_rows,
    d_offsets,
    d_offsets + 1
  );
  cudaMalloc(&d_temp_storage, temp_storage_bytes);
  cub::DeviceSegmentedReduce::Max(
    d_temp_storage,
    temp_storage_bytes,
    d_in,
    d_out,
    num_rows,
    d_offsets,
    d_offsets + 1
  );

  cudaFree(d_offsets);
  cudaFree(d_temp_storage);
}

void d_rowsum(FloatT * d_out, FloatT * d_in, IntT num_rows, IntT num_cols) {
  void *d_temp_storage = NULL;
  size_t temp_storage_bytes = 0;

  // Compute offsets of matrix
  IntT h_offsets[num_rows + 1];
  IntT *d_offsets;
  for(IntT i = 0; i < num_rows + 1; i++) {
    h_offsets[i] = i * num_cols;
  }
  cudaMalloc((void**)&d_offsets, (num_rows + 1) * sizeof(IntT));
  cudaMemcpy(d_offsets, h_offsets, (num_rows + 1) * sizeof(IntT), cudaMemcpyHostToDevice);

  // Sum over rows
  cub::DeviceSegmentedReduce::Sum(
    d_temp_storage,
    temp_storage_bytes,
    d_in,
    d_out,
    num_rows,
    d_offsets,
    d_offsets + 1
  );
  cudaMalloc(&d_temp_storage, temp_storage_bytes);
  cub::DeviceSegmentedReduce::Sum(
    d_temp_storage,
    temp_storage_bytes,
    d_in,
    d_out,
    num_rows,
    d_offsets,
    d_offsets + 1
  );

  cudaFree(d_offsets);
}

// ================ Specific ===============

__global__ void __pairwiseNorm(
  int DV,
  int PV,
  FloatT* CV,
  FloatT* MU,
  FloatT* data_node_feats,
  FloatT* patt_node_feats,
  int node_feat_dim
) {
  IntT k = threadIdx.x + blockIdx.x * blockDim.x;
  if(k < DV * PV) {
      IntT i = k / PV;
      IntT j = k % PV;
      FloatT tmp = d_norm_2(
        node_feat_dim,
        patt_node_feats + j * node_feat_dim,
        data_node_feats + i * node_feat_dim
      );
      CV[k] = tmp;
      MU[k] = -tmp;
  }
}

void d_Init_CV_MU(Graph* d_data_graph, Graph* d_patt_graph, FloatT* d_CV, FloatT* d_MU) {
  IntT DV = d_data_graph->num_nodes;
  IntT PV = d_patt_graph->num_nodes;

  int block = 1 + (DV * PV) / THREAD;
  assert(block * THREAD > DV * PV);
  __pairwiseNorm<<<block, THREAD>>>(
    DV,
    PV,
    d_CV,
    d_MU,
    d_data_graph->node_feats,
    d_patt_graph->node_feats,
    d_data_graph->node_feat_dim
  );
}

void d_VFmax_VRmax(Graph * d_data_graph, Graph * d_patt_graph,
                 FloatT * d_VF, FloatT * d_VR, FloatT * d_VFmax, FloatT * d_VRmax) {

  IntT num_rows = d_data_graph->num_nodes; // DV
  IntT num_cols = d_patt_graph->num_edges; // PE

  IntT block  = 1 + (num_rows * num_cols) / THREAD;
  assert(THREAD * block > num_rows * num_cols);

  // VFMax
  FloatT *d_VFt;
  cudaMalloc((void**)&d_VFt, num_rows * num_cols * sizeof(FloatT));
  __transpose<<<block, THREAD>>>(d_VFt, d_VF, num_rows, num_cols);
  d_rowmax(d_VFmax, d_VFt, num_cols, num_rows);
  cudaFree(d_VFt);

  // VRmax
  FloatT *d_VRt;
  cudaMalloc((void**)&d_VRt, num_rows * num_cols * sizeof(FloatT));
  __transpose<<<block, THREAD>>>(d_VRt, d_VR, num_rows, num_cols);
  d_rowmax(d_VRmax, d_VRt, num_cols, num_rows);
  cudaFree(d_VRt);
}



void d_NormProb(const IntT num_rows, const IntT num_cols, FloatT *d_x) {

  // --------------------------
  // Prep

  IntT block  = 1 + (num_rows * num_cols) / THREAD;
  assert(THREAD * block > num_rows * num_cols);

  FloatT *d_storage;
  cudaMalloc((void**)&d_storage, num_cols * sizeof(FloatT));

  // ----------------------------
  // Compute column max

  FloatT *d_xt;
  cudaMalloc((void**)&d_xt, num_rows * num_cols * sizeof(FloatT));
  __transpose<<<block, THREAD>>>(d_xt, d_x, num_rows, num_cols);
  d_rowmax(d_storage, d_xt, num_cols, num_rows);

  // --------------------------------
  // Subtract max from columns

  __rowSubExp<<<block, THREAD>>>(d_xt, num_cols, num_rows, d_storage);

  // --------------------------------
  // Sum columns

  cudaMemset(d_storage, 0, num_cols * sizeof(FloatT));
  d_rowsum(d_storage, d_xt, num_cols, num_rows);

  // ---------------------------------
  // Subtract log-sum from columns

  __rowSubLog<<<block, THREAD>>>(d_xt, num_cols, num_rows, d_storage);

  // ---------------------------------
  // Transpose back to original shape

  __transpose<<<block, THREAD>>>(d_x, d_xt, num_cols, num_rows);

  // ---------------------------------
  // Free memory

  cudaFree(d_xt);
  cudaFree(d_storage);
}



__global__ void __d_Init_VR_VF(
  const IntT DV,
  const IntT PE,
  const IntT PV,
  FloatT * MU,
  FloatT * VR,
  FloatT * VF,
  IntT * srcs,
  IntT * dsts
)
{
  IntT k = threadIdx.x + blockDim.x * blockIdx.x;

  if(k < DV * PE) {
    IntT i = k / PE;
    IntT j = k % PE;
    VR[k] = MU[i * PV + srcs[j]];
    VF[k] = MU[i * PV + dsts[j]];
  }
}

void d_Init_VR_VF(Graph * d_data_graph, Graph * d_patt_graph, FloatT * MU, FloatT * VR, FloatT * VF) {
  const IntT DV  = d_data_graph->num_nodes;
  const IntT PV  = d_patt_graph->num_nodes;
  const IntT PE  = d_patt_graph->num_edges;

  IntT block_dv_pe = 1 + (DV * PE) / THREAD;
  assert(THREAD * block_dv_pe > DV * PE);
  __d_Init_VR_VF<<<block_dv_pe, THREAD>>>(
    DV,
    PE,
    PV,
    MU,
    VR,
    VF,
    d_patt_graph->srcs,
    d_patt_graph->dsts
  );
}


// edge-edge distance table
__global__ void __d_Init_CE_RE_FE(
  IntT DE,
  IntT PE,
  FloatT * CE,
  FloatT * RE,
  FloatT * FE,
  FloatT * data_edge_feats,
  FloatT * patt_edge_feats,
  IntT edge_feat_dim
)
{
  IntT k = threadIdx.x + blockDim.x * blockIdx.x;

  if(k < DE * PE) {
    IntT i = k / PE;
    IntT j = k % PE;
    FloatT tmp = d_norm_2(
      edge_feat_dim,
      patt_edge_feats + j * edge_feat_dim,
      data_edge_feats + i * edge_feat_dim
    );
    CE[k] = tmp;
    RE[k] = - CE[k];
    FE[k] = - CE[k];
  }
}

void d_Init_CE_RE_FE(Graph * d_data_graph, Graph * d_patt_graph, FloatT * d_CE, FloatT * d_RE, FloatT * d_FE) {

  IntT DE = d_data_graph->num_edges;
  IntT PE = d_patt_graph->num_edges;

  IntT block_de_pe  = 1 + (DE * PE) / THREAD;
  assert(THREAD * block_de_pe > DE * PE);
  __d_Init_CE_RE_FE<<<block_de_pe, THREAD>>>(
    DE,
    PE,
    d_CE,
    d_RE,
    d_FE,
    d_data_graph->edge_feats,
    d_patt_graph->edge_feats,
    d_data_graph->edge_feat_dim
  );
}



__global__ void __d_VF_VR(
  IntT DV,
  IntT PE,
  IntT PV,
  FloatT * MU,
  FloatT * VR,
  FloatT * VF,
  FloatT * FMax,
  FloatT * RMax,
  IntT * srcs,
  IntT * dsts
)
{

  IntT k = threadIdx.x + blockDim.x * blockIdx.x;
  if(k < DV * PE) {
    IntT i = k / PE;
    IntT j = k % PE;
    VF[k] = MU[i * PV + dsts[j]] - FMax[k];
    VR[k] = MU[i * PV + srcs[j]] - RMax[k];
  }
}

void d_VF_VR(Graph * d_data_graph, Graph * d_patt_graph,
           FloatT * d_MU, FloatT * d_FMax, FloatT * d_RMax, FloatT * d_VF, FloatT * d_VR) {

  IntT DV = d_data_graph->num_nodes;
  IntT PV = d_patt_graph->num_nodes;
  IntT PE = d_patt_graph->num_edges;

  IntT block_dv_pe = 1 + (DV * PE) / THREAD;
  assert(THREAD * block_dv_pe > DV * PE);
  __d_VF_VR<<<block_dv_pe, THREAD>>>(
    DV,
    PE,
    PV,
    d_MU,
    d_VR,
    d_VF,
    d_FMax,
    d_RMax,
    d_patt_graph->srcs,
    d_patt_graph->dsts
  );
}

__global__ void __copyChangeSign(FloatT * d_out, FloatT * d_in, IntT num_out) {
  IntT i = threadIdx.x + blockDim.x * blockIdx.x;
  if(i < num_out)
    d_out[i] = -d_in[i];
}

__global__ void __tileVector(IntT * d_out, IntT * d_in, IntT num_in, IntT num_out) {
  IntT i = threadIdx.x + blockDim.x * blockIdx.x;
  if(i < num_out)
    d_out[i] = d_in[i % num_in];
}

__global__ void __tileVectorOffset(IntT * d_out, IntT * d_in, IntT num_in, IntT num_uin, IntT num_out) {
  IntT i = threadIdx.x + blockDim.x * blockIdx.x;
  if(i < num_out)
    d_out[i] = num_uin * (i / num_in) + d_in[i % num_in];
}

__global__ void __vectorAdd(FloatT * d_out, FloatT * d_in, IntT num_out) {
  IntT i = threadIdx.x + blockDim.x * blockIdx.x;
  if(i < num_out)
    d_out[i] += d_in[i];
}

__global__ void __vectorScatterAdd(FloatT * d_out, IntT * d_key_in, FloatT * d_value_in, IntT * n) {
  IntT i = threadIdx.x + blockDim.x * blockIdx.x;
  if(i < n[0])
    d_out[d_key_in[i]] += d_value_in[i];
}

__global__ void __tileMax(FloatT * d_out, FloatT * d_in, IntT num_in, IntT num_out) {
  IntT i = threadIdx.x + blockDim.x * blockIdx.x;
  if(i < num_out)
    d_out[i] = max(d_out[i], d_in[i % num_in]);
}

__global__ void __MU(
  IntT DV,
  IntT PV,
  IntT PE,
  IntT AT,
  IntT * srcs,
  IntT * dsts,
  FloatT * FMax,
  FloatT * RMax,
  FloatT * MU
)
{
  // Sum reduce columns of FMax/RMax by key
  // Some of the keys are sequential, some are not
  IntT k = threadIdx.x + blockDim.x * blockIdx.x;
  if(k < DV * PE) {
    IntT i = k / PE;
    IntT j = k % PE;
    atomicAdd(&MU[i * PV + dsts[j]], FMax[k]);
    atomicAdd(&MU[i * PV + srcs[j]], RMax[k]);
  }
}

void d_UpdateMU(Graph * d_data_graph, Graph * d_patt_graph, FloatT * d_CV, FloatT * d_FMax, FloatT * d_RMax, FloatT * d_MU) {
  void     *d_temp_storage = NULL;
  size_t   temp_storage_bytes = 0;

  IntT DV = d_data_graph->num_nodes;
  IntT PV = d_patt_graph->num_nodes;
  IntT PE = d_patt_graph->num_edges;

  // --------------------------------------------
  // MU = -CV

  IntT block_dv_pv = 1 + (DV * PV) / THREAD;
  assert(THREAD * block_dv_pv > DV * PV);
  __copyChangeSign<<<block_dv_pv, THREAD>>>(d_MU, d_CV, DV * PV);

  // --------------------------------------------
  // Tile srcs

  IntT *d_tiled_srcs;
  cudaMalloc((void**)&d_tiled_srcs, DV * PE * sizeof(IntT));

  IntT block_dv_pe = 1 + (DV * PE) / THREAD;
  assert(THREAD * block_dv_pe > DV * PE);
  __tileVector<<<block_dv_pe, THREAD>>>(d_tiled_srcs, d_patt_graph->srcs, PE, DV * PE);

  // --------------------------------------------
  // Sum over rows of matrix

  IntT num_items = DV * PE;
  IntT *d_keys_out;
  FloatT   *d_values_out;
  IntT *d_num_runs_out;

  cudaMalloc((void**)&d_keys_out,       DV * PV * sizeof(IntT));
  cudaMalloc((void**)&d_values_out,     DV * PV * sizeof(FloatT));
  cudaMalloc((void**)&d_num_runs_out,   1 * sizeof(IntT));

  cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes,
    d_tiled_srcs, d_keys_out, d_RMax, d_values_out, d_num_runs_out, cub::Sum(), num_items);
  cudaMalloc(&d_temp_storage, temp_storage_bytes);
  cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes,
    d_tiled_srcs, d_keys_out, d_RMax, d_values_out, d_num_runs_out, cub::Sum(), num_items);

  // --------------------------------------------
  // Add to MU
  //  !! Need scatterAdd unless all nodes guaranteed to be in `d_srcs`

  __vectorAdd<<<block_dv_pv, THREAD>>>(d_MU, d_values_out, DV * PV);

  // --------------------------------------------
  // Tile dsts

  IntT *d_tiled_dsts;
  cudaMalloc((void**)&d_tiled_dsts, DV * PE * sizeof(IntT));
  cudaMemset(d_tiled_dsts, 0, DV * PE * sizeof(IntT));
  __tileVectorOffset<<<block_dv_pe, THREAD>>>(d_tiled_dsts, d_patt_graph->dsts, PE, PV, DV * PE);

  // --------------------------------------
  // Sort keys + values (should be precomputing)

  IntT *d_keys_tmp;
  FloatT *d_values_tmp;
  cudaMalloc((void**)&d_keys_tmp,   DV * PE * sizeof(IntT));
  cudaMalloc((void**)&d_values_tmp, DV * PE * sizeof(FloatT));

  d_temp_storage = NULL;
  temp_storage_bytes = 0;
  cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
      d_tiled_dsts, d_keys_tmp, d_FMax, d_values_tmp, num_items);
  cudaMalloc(&d_temp_storage, temp_storage_bytes);
  cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
      d_tiled_dsts, d_keys_tmp, d_FMax, d_values_tmp, num_items);

  // --------------------------------------
  // Sort keys + values (should be precomputing)

  d_temp_storage = NULL; temp_storage_bytes = 0;
  cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes,
    d_keys_tmp, d_keys_out, d_values_tmp, d_values_out, d_num_runs_out, cub::Sum(), num_items);
  cudaMalloc(&d_temp_storage, temp_storage_bytes);
  cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes,
    d_keys_tmp, d_keys_out, d_values_tmp, d_values_out, d_num_runs_out, cub::Sum(), num_items);

  // --------------------------------------
  // (Scatter) add to d_MU

  __vectorScatterAdd<<<block_dv_pv, THREAD>>>(d_MU, d_keys_out, d_values_out, d_num_runs_out);

  // --------------------------------------
  // Free memory

  cudaFree(d_tiled_srcs);
  cudaFree(d_keys_out);
  cudaFree(d_values_out);
  cudaFree(d_num_runs_out);
  cudaFree(d_temp_storage);
  cudaFree(d_tiled_dsts);
  cudaFree(d_keys_tmp);
  cudaFree(d_values_tmp);
}

__global__ void __d_FE_RE(
  IntT DE,
  IntT PE,
  FloatT * CE,
  FloatT * VR,
  FloatT * VF,
  FloatT * FE,
  FloatT * RE,
  IntT * srcs
)
{
  IntT k = threadIdx.x + blockDim.x * blockIdx.x;
  if(k < DE * PE) {
    IntT ij  = k / PE;
    IntT km  = k % PE;
    IntT src = srcs[ij];
    FE[k] = - CE[k] + VR[src * PE + km];
    RE[k] = - CE[k] + VF[src * PE + km];
  }
}

void d_FE_RE(Graph * d_data_graph, Graph * d_patt_graph, FloatT * d_CE, FloatT * d_VF, FloatT * d_VR, FloatT * d_FE, FloatT * d_RE) {

  IntT DE = d_data_graph->num_edges;
  IntT PE = d_patt_graph->num_edges;

  IntT block = 1 + (DE * PE) / THREAD;
  assert(THREAD * block > DE * PE);
  __d_FE_RE<<<block, THREAD>>>(
    DE,
    PE,
    d_CE,
    d_VR,
    d_VF,
    d_FE,
    d_RE,
    d_data_graph->srcs
  );
}

void d_RMax(Graph * d_data_graph, Graph * d_patt_graph, FloatT * d_Cnull, FloatT * d_VFmax, FloatT * d_RE, FloatT * d_RMax) {
  void     *d_temp_storage = NULL;
  size_t   temp_storage_bytes = 0;

  IntT DV = d_data_graph->num_nodes;
  IntT DE = d_data_graph->num_edges;
  IntT PE = d_patt_graph->num_edges;

  // --------------------------------------
  // Transpose

  FloatT *d_REt; // PE x DE
  cudaMalloc((void**)&d_REt, DE * PE * sizeof(FloatT));

  IntT block_de_pe = 1 + (DE * PE) / THREAD;
  assert(THREAD * block_de_pe > DE * PE);
  __transpose<<<block_de_pe, THREAD>>>(d_REt, d_RE, DE, PE);

  // --------------------------------------
  // Tile srcs

  IntT *d_tiled_srcs;
  cudaMalloc((void**)&d_tiled_srcs, DE * PE * sizeof(IntT));
  cudaMemset(d_tiled_srcs, 0, DE * PE * sizeof(IntT));
  __tileVector<<<block_de_pe, THREAD>>>(d_tiled_srcs, d_data_graph->srcs, DE, DE * PE);

  // --------------------------------------
  // Max reduce rows of transposed matrix

  IntT *d_keys_out;
  FloatT   *d_values_out;
  IntT *d_num_runs_out;
  cudaMalloc((void**)&d_keys_out,       DV * PE * sizeof(IntT));
  cudaMalloc((void**)&d_values_out,     DV * PE * sizeof(FloatT));
  cudaMalloc((void**)&d_num_runs_out,   1 * sizeof(IntT));
  cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes,
    d_tiled_srcs, d_keys_out, d_REt, d_values_out, d_num_runs_out, cub::Max(), DE * PE);
  cudaMalloc(&d_temp_storage, temp_storage_bytes);
  cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes,
    d_tiled_srcs, d_keys_out, d_REt, d_values_out, d_num_runs_out, cub::Max(), DE * PE);

  // --------------------------------------
  // Transpose result back to d_RMax
  //  !! assumes all nodes in `d_srcs`, otherwise need a scatter w/ d_keys_oout

  IntT block_dv_pe = 1 + (DV * PE) / THREAD;
  assert(THREAD * block_dv_pe > DV * PE);
  __transpose<<<block_dv_pe, THREAD>>>(d_RMax, d_values_out, PE, DV);

  // --------------------------------------
  // Elementwise max w/ V*max
  //   !! CNull hardcoded to 0, so ignore

  __tileMax<<<block_dv_pe, THREAD>>>(d_RMax, d_VFmax, PE, DV * PE);

  // --------------------------------------
  // Free memory

  cudaFree(d_REt);
  cudaFree(d_tiled_srcs);
  cudaFree(d_keys_out);
  cudaFree(d_values_out);
  cudaFree(d_num_runs_out);
  cudaFree(d_temp_storage);

}


void d_FMax(Graph* d_data_graph, Graph* d_patt_graph, FloatT* d_Cnull, FloatT* d_VRmax, FloatT* d_FE, FloatT* d_FMax) {
  void     *d_temp_storage = NULL;
  size_t   temp_storage_bytes = 0;

  IntT DV = d_data_graph->num_nodes;
  IntT DE = d_data_graph->num_edges;
  IntT PE = d_patt_graph->num_edges;

  // --------------------------------------
  // Transpose

  FloatT *d_FEt;
  cudaMalloc((void**)&d_FEt, DE * PE * sizeof(FloatT));
  IntT block_de_pe = 1 + (DE * PE) / THREAD;
  assert(THREAD * block_de_pe > DE * PE);
  __transpose<<<block_de_pe, THREAD>>>(d_FEt, d_FE, DE, PE);

  // --------------------------------------
  // Tile dsts (w/ offset)

  IntT *d_tiled_dsts;
  cudaMalloc((void**)&d_tiled_dsts, DE * PE * sizeof(IntT));
  cudaMemset(d_tiled_dsts, 0, DE * PE * sizeof(IntT));
  __tileVectorOffset<<<block_de_pe, THREAD>>>(d_tiled_dsts, d_data_graph->dsts, DE, DV, DE * PE);

  // --------------------------------------
  // Sort keys + values (should be precomputing)

  IntT *d_keys_tmp;
  FloatT *d_values_tmp;
  cudaMalloc((void**)&d_keys_tmp,   DE * PE * sizeof(IntT));
  cudaMalloc((void**)&d_values_tmp, DE * PE * sizeof(FloatT));

  cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
      d_tiled_dsts, d_keys_tmp, d_FEt, d_values_tmp, DE * PE);
  cudaMalloc(&d_temp_storage, temp_storage_bytes);
  cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
      d_tiled_dsts, d_keys_tmp, d_FEt, d_values_tmp, DE * PE);

  // --------------------------------------
  // Max reduce rows of transposed matrix

  IntT *d_keys_out;
  FloatT   *d_values_out;
  IntT *d_num_runs_out;
  cudaMalloc((void**)&d_keys_out,       DV * PE * sizeof(IntT));
  cudaMalloc((void**)&d_values_out,     DV * PE * sizeof(FloatT));
  cudaMalloc((void**)&d_num_runs_out,   1 * sizeof(IntT));

  d_temp_storage = NULL; temp_storage_bytes = 0;
  cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes,
    d_keys_tmp, d_keys_out, d_values_tmp, d_values_out, d_num_runs_out, cub::Max(), DE * PE);
  cudaMalloc(&d_temp_storage, temp_storage_bytes);
  cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes,
    d_keys_tmp, d_keys_out, d_values_tmp, d_values_out, d_num_runs_out, cub::Max(), DE * PE);

  // --------------------------------------
  // Transpose result back to d_RMax
  //  !! assumes all nodes in `d_srcs`, otherwise need a scatter w/ d_keys_oout
  IntT block_dv_pe = 1 + (DV * PE) / THREAD;
  assert(THREAD * block_dv_pe > DV * PE);
  __transpose<<<block_dv_pe, THREAD>>>(d_FMax, d_values_out, PE, DV);

  // --------------------------------------
  // Elementwise max w/ V*max
  //   !! CNull hardcoded to 0, so ignore

  __tileMax<<<block_dv_pe, THREAD>>>(d_FMax, d_VRmax, PE, DV * PE);

  // -------------------------------------
  // Free memory

  cudaFree(d_FEt);
  cudaFree(d_tiled_dsts);
  cudaFree(d_keys_tmp);
  cudaFree(d_values_tmp);
  cudaFree(d_temp_storage);
  cudaFree(d_keys_out);
  cudaFree(d_values_out);
  cudaFree(d_num_runs_out);
}

