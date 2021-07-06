#include <stdint.h>
#include <stdio.h>
#include <thrust/transform.h>
#include <thrust/transform_reduce.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/functional.h>
#include "types.h"

const int CUDA_THREAD_BLOCK_SIZE = 256;

/*****************************************************/
/* KERNEL: RUN SINGLE RANK ITERATION                 */
/*****************************************************/
/* All in links used here are compressed in links    */
/*****************************************************/
__global__
void run_rank_iteration(
    CompressedInLink *inLinks,                            /* all compressed in links */
    double *prevRank, double *rank, uint64_t rankSize,    /* array index - cid index */
    uint64_t *inLinksStartIndex, uint32_t *inLinksCount,  /* array index - cid index */
    double defaultRankWithCorrection,                     /* default rank + inner product correction */
    double dampingFactor
) {

	int index = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = blockDim.x * gridDim.x;

    for (uint64_t i = index; i < rankSize; i += stride) {

        if(inLinksCount[i] == 0) {
            continue;
        }

        double ksum = 0;
        for (uint64_t j = inLinksStartIndex[i]; j < inLinksStartIndex[i] + inLinksCount[i]; j++) {
           ksum = prevRank[inLinks[j].fromIndex] * inLinks[j].weight + ksum;
           //ksum = __fmaf_rn(prevRank[inLinks[j].fromIndex], inLinks[j].weight, ksum);
        }
        rank[i] = ksum * dampingFactor + defaultRankWithCorrection;
        //rank[i] = __fmaf_rn(ksum, dampingFactor, defaultRankWithCorrection);
    }
}


/*****************************************************/
/* KERNEL: DOUBLE ABS FUNCTOR                        */
/*****************************************************/
/* Return absolute value for double                  */
/*****************************************************/
struct absolute_value {
  __device__ double operator()(const double &x) const {
    return x < 0.0 ? -x : x;
  }
};


/*****************************************************/
/* HOST: FINDS MAXIMUM RANKS DIFFERENCE              */
/*****************************************************/
/* Finds maximum rank difference for single element  */
/*                                                   */
/*****************************************************/
double find_max_ranks_diff(double *prevRank, double *newRank, uint64_t rankSize) {

    thrust::device_vector<double> ranksDiff(rankSize);
    thrust::device_ptr<double> newRankBegin(newRank);
    thrust::device_ptr<double> prevRankBegin(prevRank);
    thrust::device_ptr<double> prevRankEnd(prevRank + rankSize);
    thrust::transform(thrust::device,
        prevRankBegin, prevRankEnd, newRankBegin, ranksDiff.begin(), thrust::minus<double>()
    );

    return thrust::transform_reduce(thrust::device,
        ranksDiff.begin(), ranksDiff.end(), absolute_value(), 0.0, thrust::maximum<double>()
    );
}

/*****************************************************/
/* KERNEL: CALCULATE CID TOTAL OUTS STAKE            */
/*****************************************************/
__global__
void calculateCidTotalOutStake(
    uint64_t cidsSize,
    uint64_t *stakes,                                        /*array index - user index*/
    uint64_t *outLinksStartIndex, uint32_t *outLinksCount,   /*array index - cid index*/
    uint64_t *outLinksUsers,                                 /*all out links from all users*/
    /*returns*/ uint64_t *cidsTotalOutStakes                 /*array index - cid index*/
) {

	int index = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = blockDim.x * gridDim.x;

    for (uint64_t i = index; i < cidsSize; i += stride) {
        uint64_t totalOutStake = 0;
        for (uint64_t j = outLinksStartIndex[i]; j < outLinksStartIndex[i] + outLinksCount[i]; j++) {
           totalOutStake += stakes[outLinksUsers[j]];
        }
        cidsTotalOutStakes[i] = totalOutStake;
    }
}

/*********************************************************/
/* DEVICE: USER TO DIVIDE TWO uint64                     */
/*********************************************************/
__device__ __forceinline__
double ddiv_rn(uint64_t *a, uint64_t *b) {
    return __ddiv_rn(__ull2double_rn(*a), __ull2double_rn(*b));
}

/*****************************************************/
/* KERNEL: CALCULATE PERSONAL LINK NODE WEIGHT        */
/*****************************************************/
__global__
void calculateCyberlinksLocalWeights(
    uint64_t cidsSize,
    uint64_t *stakes,                                        /*array index - user index*/
    uint64_t *outLinksStartIndex, uint32_t *outLinksCount,   /*array index - cid index*/
    uint64_t *outLinksUsers,                                 /*all out links from all users*/
    uint64_t *cidsTotalOutStakes,                            /*array index - cid index*/
    uint64_t *cidsTotalInStakes,                             /*array index - cid index*/
    /*returns*/ double *cyberlinksLocalWeights                 /*array index - cid index*/
) {

	int index = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = blockDim.x * gridDim.x;

    for (uint64_t i = index; i < cidsSize; i += stride) {
        uint64_t oil = cidsTotalOutStakes[i] + cidsTotalInStakes[i]; 
        for (uint64_t j = outLinksStartIndex[i]; j < outLinksStartIndex[i] + outLinksCount[i]; j++) {
            double weight = ddiv_rn(&stakes[outLinksUsers[j]], &oil);
            cyberlinksLocalWeights[j] = weight;
        }
    }
}

/*****************************************************/
/* KERNEL: CALCULATE CIDS TOTAL ENTROPY              */
/*****************************************************/
__global__
void calculateNodeEntropy(
    uint64_t cidsSize,
    uint64_t *stakes,                                        /*array index - user index*/
    uint64_t *outLinksStartIndex, uint32_t *outLinksCount,   /*array index - cid index*/
    uint64_t *outLinksUsers,                                 /*all out links from all users*/
    uint64_t *cidsTotalOutStakes,                             /*array index - cid index*/
    uint64_t *cidsTotalInStakes,                             /*array index - cid index*/
    /*returns*/ double *nodesTotalEntropy               /*array index - cid index*/
) {

	int index = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = blockDim.x * gridDim.x;

    for (uint64_t i = index; i < cidsSize; i += stride) {
        double nodeLinksEntropy = 0;
        uint64_t oil = cidsTotalOutStakes[i] + cidsTotalInStakes[i]; 
        // uint64_t oil = cidsTotalOutStakes[i];
        for (uint64_t j = outLinksStartIndex[i]; j < outLinksStartIndex[i] + outLinksCount[i]; j++) {
           double weight = ddiv_rn(&stakes[outLinksUsers[j]], &oil);
           double logw = log2(weight);
           nodeLinksEntropy -= __dmul_rn(weight,logw);
        }
        nodesTotalEntropy[i] = nodeLinksEntropy;
    }
}

/*********************************************************/
/* KERNEL: MULTIPLY TWO ARRAYS                           */
/*********************************************************/
__global__
void mulArrays(
    uint64_t size,
    double *in1,
    double *in2,
    double *output
) {
    int tx = blockIdx.x * blockDim.x + threadIdx.x;
    if (tx < size) output[tx] = __dmul_rn(in1[tx], in2[tx]);
}


// TODO: use for in out stakes
/*********************************************************/
/* KERNEL: SUM TWO ARRAYS                           */
/*********************************************************/
__global__ void sumArrays(
    uint64_t size,
    double *in1,
    double *in2,
    double *output
) {
    int tx = blockIdx.x * blockDim.x + threadIdx.x;
    if (tx < size) output[tx] = __dadd_rn(in1[tx], in2[tx]);
}

// TODO: use for in out stakes
/*********************************************************/
/* KERNEL: CALCULATE SI                          */
/*********************************************************/
__global__ void calculate_SI(
    uint64_t size,
    uint64_t *out,
    uint64_t *in,
    double *d_si,
    double damping
) {
    int tx = blockIdx.x * blockDim.x + threadIdx.x;
    if (tx < size) d_si[tx] = __dadd_rn(__dmul_rn(damping, __ull2double_rn(in[tx])), __dmul_rn(1-damping, __ull2double_rn(out[tx])));
}

/*****************************************************/
/* KERNEL: CALCULATE CIDS TOTAL ENTROPY              */
/*****************************************************/
__global__
void calculate_QJ(
    uint64_t cidsSize,
    uint64_t *outLinksStartIndex, uint32_t *outLinksCount,   /*array index - cid index*/
    uint64_t *inLinksOuts,  
    double *si,
    double damping,
    /*returns*/ double *qj
) {

	int index = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = blockDim.x * gridDim.x;

    for (uint64_t i = index; i < cidsSize; i += stride) {
        // double nodeLinksEntropy = 0;
        // uint64_t oil = cidsTotalOutStakes[i] + cidsTotalInStakes[i]; 
        // uint64_t oil = cidsTotalOutStakes[i];
        // double qj_node = 0;
        for (uint64_t j = outLinksStartIndex[i]; j < outLinksStartIndex[i] + outLinksCount[i]; j++) {
            qj[i] = __dadd_rn(qj[i],__dmul_rn(damping,si[inLinksOuts[j]]));

        //    double weight = ddiv_rn(&stakes[outLinksUsers[j]], &oil);
        //    double logw = log2(weight);
        //    nodeLinksEntropy -= __dmul_rn(weight,logw);
            // qj_node += __dmul_rn(damping,si[j]);
        }
        // qj[i] = qj_node;
    }
}

__global__
void calculate_ENT(
    uint64_t cidsSize,
    uint64_t *outLinksStartIndex, uint32_t *outLinksCount,   /*array index - cid index*/
    uint64_t *inLinksOuts,  
    double *si,
    double *qj,
    /*returns*/ double *ent
) {

	int index = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = blockDim.x * gridDim.x;

    for (uint64_t i = index; i < cidsSize; i += stride) {
        // double nodeLinksEntropy = 0;
        // uint64_t oil = cidsTotalOutStakes[i] + cidsTotalInStakes[i]; 
        // uint64_t oil = cidsTotalOutStakes[i];
        // double qj_node = 0;
        for (uint64_t j = outLinksStartIndex[i]; j < outLinksStartIndex[i] + outLinksCount[i]; j++) {
            double weight = __ddiv_rn(si[i],qj[inLinksOuts[j]]);
            double logw = log2(weight);
            ent[i] = __dadd_rn(ent[i],fabs(__dmul_rn(weight, logw)));

        //    double weight = ddiv_rn(&stakes[outLinksUsers[j]], &oil);
        //    double logw = log2(weight);
        //    nodeLinksEntropy -= __dmul_rn(weight,logw);
            // qj_node += __dmul_rn(damping,si[j]);
        }
        // qj[i] = qj_node;
    }
}

/*********************************************************/
/* KERNEL: CALCULATE COMPRESSED IN LINKS COUNT FOR CIDS  */
/*********************************************************/
__global__
void getCompressedInLinksCount(
    uint64_t cidsSize,
    uint64_t *inLinksStartIndex, uint32_t *inLinksCount,                    /*array index - cid index*/
    uint64_t *inLinksOuts,                                                  /*all incoming links from all users*/
    /*returns*/ uint32_t *compressedInLinksCount                            /*array index - cid index*/
) {

	int index = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = blockDim.x * gridDim.x;

    for (uint64_t i = index; i < cidsSize; i += stride) {

        if(inLinksCount[i] == 0) {
            compressedInLinksCount[i]=0;
            continue;
        }

        uint32_t compressedLinksCount = 0;
        for(uint64_t j = inLinksStartIndex[i]; j < inLinksStartIndex[i]+inLinksCount[i]; j++) {
            if(j == inLinksStartIndex[i] || inLinksOuts[j] != inLinksOuts[j-1]) {
                compressedLinksCount++;
            }
        }
        compressedInLinksCount[i] = compressedLinksCount;
    }
}


/*********************************************************/
/* KERNEL: CALCULATE COMPRESSED IN LINKS                 */
/*********************************************************/
__global__
void getCompressedInLinks(
    uint64_t cidsSize,
    uint64_t *inLinksStartIndex, uint32_t *inLinksCount, uint64_t *cidsTotalOutStakes,   /*array index - cid index*/
    uint64_t *inLinksOuts, uint64_t *inLinksUsers,                                       /*all incoming links from all users*/
    uint64_t *stakes,                                                                    /*array index - user index*/
    uint64_t *compressedInLinksStartIndex, uint32_t *compressedInLinksCount,             /*array index - cid index*/
    /*returns*/ CompressedInLink *compressedInLinks                                      /*all incoming compressed links*/
) {

	int index = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = blockDim.x * gridDim.x;

    for (uint64_t i = index; i < cidsSize; i += stride) {

        if(inLinksCount[i] == 0) {
            continue;
        }

        uint32_t compressedLinksIndex = compressedInLinksStartIndex[i];

        if(inLinksCount[i] == 1) {
            uint64_t oppositeCid = inLinksOuts[inLinksStartIndex[i]];
            uint64_t compressedLinkStake = stakes[inLinksUsers[inLinksStartIndex[i]]];
            double weight = ddiv_rn(&compressedLinkStake, &cidsTotalOutStakes[oppositeCid]);
            compressedInLinks[compressedLinksIndex] = CompressedInLink {oppositeCid, weight};
            continue;
        }

        uint64_t compressedLinkStake = 0;
        uint64_t lastLinkIndex = inLinksStartIndex[i] + inLinksCount[i] - 1;
        for(uint64_t j = inLinksStartIndex[i]; j < lastLinkIndex + 1; j++) {

            compressedLinkStake += stakes[inLinksUsers[j]];
            if(j == lastLinkIndex || inLinksOuts[j] != inLinksOuts[j+1]) {
                uint64_t oppositeCid = inLinksOuts[j];
                double weight = ddiv_rn(&compressedLinkStake, &cidsTotalOutStakes[oppositeCid]);
                compressedInLinks[compressedLinksIndex] = CompressedInLink {oppositeCid, weight};
                compressedLinksIndex++;
                compressedLinkStake=0;
            }
        }
    }
}

__global__
void calculateKarma(
    uint64_t cidsSize,
    uint64_t *outLinksStartIndex, uint32_t *outLinksCount,
    uint64_t *outLinksUsers,      
    double *cyberlinksLocalWeights,
    double *light,
    /*returns*/ double *karma
) {
    for (uint64_t i = 0; i < cidsSize; i++) {          
        for (uint64_t j = outLinksStartIndex[i]; j < outLinksStartIndex[i] + outLinksCount[i]; j++) {
            karma[outLinksUsers[j]] += light[i]*cyberlinksLocalWeights[j];
        }
    }
}

/************************************************************/
/* HOST: CALCULATE COMPRESSED IN LINKS START INDEXES        */
/************************************************************/
/* SEQUENTIAL LOGIC -> CALCULATE ON CPU                     */
/* RETURNS TOTAL COMPRESSED LINKS SIZE                      */
/************************************************************/
__host__
uint64_t getLinksStartIndex(
    uint64_t cidsSize,
    uint32_t *linksCount,                   /*array index - cid index*/
    /*returns*/ uint64_t *linksStartIndex   /*array index - cid index*/
) {

    uint64_t index = 0;
    for (uint64_t i = 0; i < cidsSize; i++) {
        linksStartIndex[i] = index;
        index += linksCount[i];
    }
    return index;
}

void swap(double* &a, double* &b){
  double *temp = a;
  a = b;
  b = temp;
}

void printSize(size_t usageOffset) {
	size_t free = 0, total = 0;
	cudaMemGetInfo(&free, &total);
	fprintf(stderr, "-[GPU]: Free: %.2fMB\tUsed: %.2fMB\n", free / 1048576.0f, (total - usageOffset - free) / 1048576.0f);
}

extern "C" {

    void calculate_rank(
        uint64_t *stakes, uint64_t stakesSize,                    /* User stakes and corresponding array size */
        uint64_t cidsSize, uint64_t linksSize,                    /* Cids count */
        uint32_t *inLinksCount, uint32_t *outLinksCount,          /* array index - cid index*/
        uint64_t *outLinksIns,
        uint64_t *inLinksOuts, uint64_t *inLinksUsers,            /*all incoming links from all users*/
        uint64_t *outLinksUsers,                                  /*all outgoing links from all users*/
        double *rank,                                             /* array index - cid index*/
        double dampingFactor,                                     /* value of damping factor*/
        double tolerance,                                         /* value of needed tolerance */
        double *entropy,                                          /* array index - cid index*/
        double *light,                                            /* array index - cid index*/
        double *karma                                             /* array index - account index*/
    ) {

        // setbuf(stdout, NULL);
        int CUDA_BLOCKS_NUMBER = (cidsSize + CUDA_THREAD_BLOCK_SIZE - 1) / CUDA_THREAD_BLOCK_SIZE;

        size_t freeStart = 0, totalStart = 0, usageOffset = 0;
        cudaMemGetInfo(&freeStart, &totalStart);
        usageOffset = totalStart - freeStart;
        fprintf(stderr, "[GPU]: Usage Offset: %.2fMB\n", usageOffset / 1048576.0f);

        // STEP0: Calculate compressed in links start indexes
        /*-------------------------------------------------------------------*/
        // calculated on cpu
        printf("STEP0: Calculate compressed in links start indexes\n");

        uint64_t *inLinksStartIndex = (uint64_t*) malloc(cidsSize*sizeof(uint64_t));
        uint64_t *outLinksStartIndex = (uint64_t*) malloc(cidsSize*sizeof(uint64_t));
        getLinksStartIndex(cidsSize, inLinksCount, inLinksStartIndex);
        getLinksStartIndex(cidsSize, outLinksCount, outLinksStartIndex);
        
        printSize(usageOffset);

        // STEP1: Calculate for each cid total stake by out links
        /*-------------------------------------------------------------------*/
        printf("STEP1: Calculate for each cid total stake by out links\n");
        
        uint64_t *d_outLinksStartIndex;
        uint32_t *d_outLinksCount;
        uint64_t *d_outLinksUsers;
        uint64_t *d_stakes;  // will be used to calculated links weights, should be freed before rank iterations
        uint64_t *d_cidsTotalOutStakes; // will be used to calculated links weights, should be freed before rank iterations

        cudaMalloc(&d_outLinksStartIndex, cidsSize*sizeof(uint64_t));
        cudaMalloc(&d_outLinksCount,      cidsSize*sizeof(uint32_t));
        cudaMalloc(&d_outLinksUsers,     linksSize*sizeof(uint64_t));
        cudaMalloc(&d_stakes,           stakesSize*sizeof(uint64_t));
        cudaMalloc(&d_cidsTotalOutStakes, cidsSize*sizeof(uint64_t));   //calculated

        cudaMemcpy(d_outLinksStartIndex, outLinksStartIndex, cidsSize*sizeof(uint64_t), cudaMemcpyHostToDevice);
        cudaMemcpy(d_outLinksCount,      outLinksCount,      cidsSize*sizeof(uint32_t), cudaMemcpyHostToDevice);
        cudaMemcpy(d_outLinksUsers,      outLinksUsers,     linksSize*sizeof(uint64_t), cudaMemcpyHostToDevice);
        cudaMemcpy(d_stakes,             stakes,           stakesSize*sizeof(uint64_t), cudaMemcpyHostToDevice);

        calculateCidTotalOutStake<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_stakes, d_outLinksStartIndex,
            d_outLinksCount, d_outLinksUsers, d_cidsTotalOutStakes
        );

        printSize(usageOffset);

        // DEV ENTROPY (in+out stake)
        /*-------------------------------------------------------------------*/
        printf("DEV ENTROPY 222- IN STAKE\n");

        uint64_t *d_inLinksStartIndex0;
        uint32_t *d_inLinksCount0;
        uint64_t *d_inLinksUsers0;
        uint64_t *d_cidsTotalInStakes; // will be used to calculated links weights, should be freed before rank iterations

        cudaMalloc(&d_inLinksStartIndex0, cidsSize*sizeof(uint64_t));
        cudaMalloc(&d_inLinksCount0,      cidsSize*sizeof(uint32_t));
        cudaMalloc(&d_inLinksUsers0,      linksSize*sizeof(uint64_t));
        cudaMalloc(&d_cidsTotalInStakes, cidsSize*sizeof(uint64_t));   //calculated
        
        cudaMemcpy(d_inLinksStartIndex0, inLinksStartIndex, cidsSize*sizeof(uint64_t), cudaMemcpyHostToDevice);
        cudaMemcpy(d_inLinksCount0,      inLinksCount,      cidsSize*sizeof(uint32_t), cudaMemcpyHostToDevice);
        cudaMemcpy(d_inLinksUsers0,      inLinksUsers,      linksSize*sizeof(uint64_t), cudaMemcpyHostToDevice);

        calculateCidTotalOutStake<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_stakes, d_inLinksStartIndex0,
            d_inLinksCount0, d_inLinksUsers0, d_cidsTotalInStakes
        );

        // cudaFree(d_inLinksStartIndex0);
        // cudaFree(d_inLinksCount0);
        // cudaFree(d_inLinksUsers0);

        // thrust::device_ptr<uint64_t> outP(d_cidsTotalOutStakes);
        // thrust::device_ptr<uint64_t> inP(d_cidsTotalInStakes);
        // for(uint64_t i = 0; i < 21; i++) {
        //     printf("[%d] = %d | %d\n",i,(uint64_t)*(outP+i), (uint64_t)*(inP+i));
        // }
        printSize(usageOffset);


        double *d_si;
        cudaMalloc(&d_si, cidsSize*sizeof(double));
        cudaMemcpy(d_si, entropy, cidsSize*sizeof(double), cudaMemcpyHostToDevice);

        calculate_SI<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_cidsTotalOutStakes, d_cidsTotalInStakes, d_si, dampingFactor);
        thrust::device_ptr<double> SI(d_si);
        for(uint64_t i = 0; i < 21; i++) {
            printf("[%d] = %f\n",i,(double)*(SI+i));
        }

        printf("DEV ENTROPY 222- ENTROPY OUT\n");

        double *d_entropy_out;
        cudaMalloc(&d_entropy_out, cidsSize*sizeof(double));
        cudaMemcpy(d_entropy_out, entropy, cidsSize*sizeof(double), cudaMemcpyHostToDevice);

        calculateNodeEntropy<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_stakes, d_outLinksStartIndex,
            d_outLinksCount, d_outLinksUsers, d_cidsTotalOutStakes, d_cidsTotalInStakes, d_entropy_out
        );
        // cudaMemcpy(entropy, d_entropy, cidsSize * sizeof(double), cudaMemcpyDeviceToHost);
        
        printSize(usageOffset);
        
        /*-----------*/

        printf("DEV ENTROPY - ENTROPY IN\n");

        double *d_entropy_in;
        cudaMalloc(&d_entropy_in, cidsSize*sizeof(double));
        cudaMemcpy(d_entropy_in, entropy, cidsSize*sizeof(double), cudaMemcpyHostToDevice);

        calculateNodeEntropy<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_stakes, d_inLinksStartIndex0,
            d_inLinksCount0, d_inLinksUsers0, d_cidsTotalOutStakes, d_cidsTotalInStakes, d_entropy_in
        );
        // cudaMemcpy(entropy, d_entropy, cidsSize * sizeof(double), cudaMemcpyDeviceToHost);
        
        // TODO Refactor steps, optimize allocation
        // cudaFree(d_inLinksStartIndex0);
        // cudaFree(d_inLinksCount0);
        // cudaFree(d_inLinksUsers0);

        printSize(usageOffset);

                
        /*-----------*/
        printf("SUM ENTROPY - IN+OUT\n");

        double *d_entropy;
        cudaMalloc(&d_entropy, cidsSize*sizeof(double));
        cudaMemcpy(d_entropy, entropy, cidsSize*sizeof(double), cudaMemcpyHostToDevice);

        sumArrays<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_entropy_out, d_entropy_in, d_entropy
        );

        cudaFree(d_entropy_out);
        cudaFree(d_entropy_in);

        printSize(usageOffset);
        /*-----------*/

        printf("LOCAL WEIGHTS\n");

        double *d_cyberlinksLocalWeights;
        cudaMalloc(&d_cyberlinksLocalWeights, linksSize*sizeof(double));
        
        calculateCyberlinksLocalWeights<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_stakes, d_outLinksStartIndex,
            d_outLinksCount, d_outLinksUsers, d_cidsTotalOutStakes, d_cidsTotalInStakes, d_cyberlinksLocalWeights
        );

        printSize(usageOffset);
        /*-------------------------------------------------------------------*/

        // cudaFree(d_outLinksStartIndex);
        // cudaFree(d_outLinksCount);
        // cudaFree(d_outLinksUsers);
        /*-------------------------------------------------------------------*/



        // STEP2: Calculate compressed in links count
        /*-------------------------------------------------------------------*/
        printf("STEP2: Calculate compressed in links count\n");

        uint64_t *d_inLinksStartIndex;
        uint32_t *d_inLinksCount;
        uint64_t *d_inLinksOuts;
        uint32_t *d_compressedInLinksCount;

        // free all before rank iterations
        cudaMalloc(&d_inLinksStartIndex,      cidsSize*sizeof(uint64_t));
        cudaMalloc(&d_inLinksCount,           cidsSize*sizeof(uint32_t));
        cudaMalloc(&d_inLinksOuts,           linksSize*sizeof(uint64_t));
        cudaMalloc(&d_compressedInLinksCount, cidsSize*sizeof(uint32_t));   //calculated

        cudaMemcpy(d_inLinksStartIndex, inLinksStartIndex, cidsSize*sizeof(uint64_t), cudaMemcpyHostToDevice);
        cudaMemcpy(d_inLinksCount,      inLinksCount,      cidsSize*sizeof(uint32_t), cudaMemcpyHostToDevice);
        cudaMemcpy(d_inLinksOuts,       inLinksOuts,      linksSize*sizeof(uint64_t), cudaMemcpyHostToDevice);

        getCompressedInLinksCount<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_inLinksStartIndex, d_inLinksCount, d_inLinksOuts, d_compressedInLinksCount
        );
        printSize(usageOffset);
        /*-------------------------------------------------------------------*/

        printf("-______________in____________\n");

        double *d_qj_in;
        cudaMalloc(&d_qj_in, cidsSize*sizeof(double));
        cudaMemset(d_qj_in, 0, cidsSize*sizeof(double));
        // cudaMemcpy(d_qj_in, entropy, cidsSize*sizeof(double), cudaMemcpyHostToDevice);

        calculate_QJ<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_inLinksStartIndex,
            d_inLinksCount, d_inLinksOuts, d_si, 0.8f, d_qj_in);
        
        thrust::device_ptr<double> QJ_IN(d_qj_in);
        for(uint64_t i = 0; i < 21; i++) {
            printf("[%d] = %f\n",i,(double)*(QJ_IN+i));
        }

        printf("-_______________out__________\n");

        uint64_t *d_outLinksIns;
        cudaMalloc(&d_outLinksIns,linksSize*sizeof(uint64_t));
        cudaMemcpy(d_outLinksIns,outLinksIns,linksSize*sizeof(uint64_t), cudaMemcpyHostToDevice);

        double *d_qj_out;
        cudaMalloc(&d_qj_out, cidsSize*sizeof(double));
        cudaMemset(d_qj_out, 0, cidsSize*sizeof(double));
        // cudaMemcpy(d_qj_out, entropy, cidsSize*sizeof(double), cudaMemcpyHostToDevice);

        calculate_QJ<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_outLinksStartIndex,
            d_outLinksCount, d_outLinksIns, d_si, 0.2f, d_qj_out);
        
        thrust::device_ptr<double> QJ_OUT(d_qj_out);
        for(uint64_t i = 0; i < 21; i++) {
            printf("[%d] = %f\n",i,(double)*(QJ_OUT+i));
        }

        printf("-_____________sum____________\n");

        double *d_qj_sum;
        cudaMalloc(&d_qj_sum, cidsSize*sizeof(double));
        cudaMemcpy(d_qj_sum, entropy, cidsSize*sizeof(double), cudaMemcpyHostToDevice);

        sumArrays<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_qj_out, d_qj_in, d_qj_sum
        );
        thrust::device_ptr<double> QJ(d_qj_sum);
        for(uint64_t i = 0; i < 21; i++) {
            printf("[%d] = %f\n",i,(double)*(QJ+i));
        }

                printf("-______________in-ent____________\n");

        double *d_ent_chi;
        cudaMalloc(&d_ent_chi, cidsSize*sizeof(double));
        cudaMemset(d_ent_chi, 0, cidsSize*sizeof(double));
        // cudaMemcpy(d_qj_in, entropy, cidsSize*sizeof(double), cudaMemcpyHostToDevice);

        calculate_ENT<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize, d_inLinksStartIndex,
            d_inLinksCount, d_inLinksOuts, d_si, d_qj_sum, d_ent_chi);

        calculate_ENT<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
        cidsSize, d_outLinksStartIndex,
        d_outLinksCount, d_outLinksIns, d_si, d_qj_sum, d_ent_chi);
        
        thrust::device_ptr<double> ENT(d_ent_chi);
        for(uint64_t i = 0; i < 21; i++) {
            printf("[%d] = %f\n",i,(double)*(ENT+i));
        }

        cudaFree(d_si);
        cudaFree(d_qj_in);
        cudaFree(d_qj_out);
        cudaFree(d_qj_sum);
        cudaFree(d_ent_chi);


        // STEP3: Calculate compressed in links start indexes
        /*-------------------------------------------------------------------*/
        printf("STEP3: Calculate compressed in links start indexes\n");

        uint32_t *compressedInLinksCount = (uint32_t*) malloc(cidsSize*sizeof(uint32_t));
        uint64_t *compressedInLinksStartIndex = (uint64_t*) malloc(cidsSize*sizeof(uint64_t));
        cudaMemcpy(compressedInLinksCount, d_compressedInLinksCount, cidsSize * sizeof(uint32_t), cudaMemcpyDeviceToHost);

        // calculated on cpu
        uint64_t compressedInLinksSize = getLinksStartIndex(
            cidsSize, compressedInLinksCount, compressedInLinksStartIndex
        );

        uint64_t *d_compressedInLinksStartIndex;
        cudaMalloc(&d_compressedInLinksStartIndex, cidsSize*sizeof(uint64_t));
        cudaMemcpy(d_compressedInLinksStartIndex, compressedInLinksStartIndex, cidsSize*sizeof(uint64_t), cudaMemcpyHostToDevice);
        free(compressedInLinksStartIndex);

        printSize(usageOffset);
        /*-------------------------------------------------------------------*/

        // STEP4: Calculate compressed in links
        /*-------------------------------------------------------------------*/
        printf("STEP4: Calculate compressed in links\n");

        uint64_t *d_inLinksUsers;
        CompressedInLink *d_compressedInLinks; //calculated

        cudaMalloc(&d_inLinksUsers,                   linksSize*sizeof(uint64_t));
        cudaMalloc(&d_compressedInLinks,  compressedInLinksSize*sizeof(CompressedInLink));
        cudaMemcpy(d_inLinksUsers, inLinksUsers,      linksSize*sizeof(uint64_t), cudaMemcpyHostToDevice);

        getCompressedInLinks<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize,
            d_inLinksStartIndex, d_inLinksCount, d_cidsTotalOutStakes,
            d_inLinksOuts, d_inLinksUsers, d_stakes,
            d_compressedInLinksStartIndex, d_compressedInLinksCount,
            d_compressedInLinks
        );

        cudaFree(d_inLinksUsers);
        cudaFree(d_inLinksStartIndex);
        cudaFree(d_inLinksCount);
        cudaFree(d_inLinksOuts);
        cudaFree(d_stakes);
        cudaFree(d_cidsTotalOutStakes);
        cudaFree(d_cidsTotalInStakes);

        printSize(usageOffset);
        /*-------------------------------------------------------------------*/



        // STEP5: Calculate dangling nodes rank, and default rank
        /*-------------------------------------------------------------------*/
        printf("STEP5: Calculate dangling nodes rank, and default rank\n");

        double defaultRank = (1.0 - dampingFactor) / cidsSize;
        uint64_t danglingNodesSize = 0;
        for(uint64_t i=0; i< cidsSize; i++){
            rank[i] = defaultRank;
            if(inLinksCount[i] == 0) {
                danglingNodesSize++;
            }
        }

        double innerProductOverSize = defaultRank * ((double) danglingNodesSize / (double)cidsSize);
        double defaultRankWithCorrection = (dampingFactor * innerProductOverSize) + defaultRank; //fma point

        printSize(usageOffset);
        /*-------------------------------------------------------------------*/




        // STEP6: Calculate Rank
        /*-------------------------------------------------------------------*/
        printf("STEP6: Calculate Rank\n");

        double *d_rank, *d_prevRank;

        cudaMalloc(&d_rank, cidsSize*sizeof(double));
        cudaMalloc(&d_prevRank, cidsSize*sizeof(double));

        cudaMemcpy(d_rank,     rank, cidsSize*sizeof(double), cudaMemcpyHostToDevice);
        cudaMemcpy(d_prevRank, rank, cidsSize*sizeof(double), cudaMemcpyHostToDevice);

        int steps = 0;
        double change = tolerance + 1.0;
        while(change > tolerance) {
            swap(d_rank, d_prevRank);
            steps++;
        	run_rank_iteration<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
                d_compressedInLinks,
                d_prevRank, d_rank, cidsSize,
                d_compressedInLinksStartIndex, d_compressedInLinksCount,
                defaultRankWithCorrection, dampingFactor
        	);
        	change = find_max_ranks_diff(d_prevRank, d_rank, cidsSize);
        	cudaDeviceSynchronize();
        }

        cudaMemcpy(rank, d_rank, cidsSize * sizeof(double), cudaMemcpyDeviceToHost);
        
        printSize(usageOffset);
        /*-------------------------------------------------------------------*/
        printf("STEP7: Calculate Light\n");

        double *d_light;
        cudaMalloc(&d_light, cidsSize*sizeof(double));
        cudaMemcpy(d_light, light, cidsSize*sizeof(double), cudaMemcpyHostToDevice);
        mulArrays<<<CUDA_BLOCKS_NUMBER,CUDA_THREAD_BLOCK_SIZE>>>(
            cidsSize,d_rank,d_entropy,d_light
        );
        cudaMemcpy(light, d_light, cidsSize * sizeof(double), cudaMemcpyDeviceToHost);

        cudaFree(d_entropy);
        cudaFree(d_rank);
        cudaFree(d_prevRank);
        cudaFree(d_compressedInLinksStartIndex);
        cudaFree(d_compressedInLinksCount);
        cudaFree(d_compressedInLinks);

        printSize(usageOffset);
        /*-------------------------------------------------------------------*/
        printf("STEP8: Calculate Karma\n");

        double *d_karma;
        cudaMalloc(&d_karma, stakesSize*sizeof(double));
        cudaMemcpy(d_karma, karma, stakesSize*sizeof(double), cudaMemcpyHostToDevice);
        calculateKarma<<<1,1>>>(
            cidsSize,
            d_outLinksStartIndex,
            d_outLinksCount,
            d_outLinksUsers,
            d_cyberlinksLocalWeights,
            d_light,
            d_karma
        );
        cudaMemcpy(karma, d_karma, stakesSize * sizeof(double), cudaMemcpyDeviceToHost);
        printSize(usageOffset);
        /*-----------------*/
        printf("STEP9: Cleaning\n");

        cudaFree(d_outLinksStartIndex);
        cudaFree(d_outLinksCount);
        cudaFree(d_outLinksUsers);

        cudaFree(d_light);
        cudaFree(d_karma);

        cudaFree(d_cyberlinksLocalWeights);

        printSize(usageOffset);
    }
};
