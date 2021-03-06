#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <getopt.h>

#include <cuda_runtime.h>
#include "micro-app-cuda.h"

float pt_data[NPOINTS * 3];
float edge_data[NEDGES];
struct graph gr;

void print_help() {
    printf("Usage: \n");
    printf("\t --help print this message and exit \n");
    printf("\t --type Type of graph, must be one of:\n");
    printf("\t\t\t pure_random \n");
    printf("\t\t\t regular_random \n");
    printf("\t\t\t contiguous \n");
    printf("\t\t\t file \n");
    printf("\t --nloops Number of repetitions, must be \n");
    printf("\t          at least one. \n");
    printf("\t --file File from which to read graph \n");
}

double timer() {
    struct timeval tp;
    struct timezone tzp;

    gettimeofday(&tp, &tzp);
    return ((double)tp.tv_sec) + ((double) tp.tv_usec) * 1e-6;
}

int data_init() {
    int i;

    for (i = 0; i < NPOINTS; i++) {
        pt_data[3*i+0] = 1;
        pt_data[3*i+1] = 1;
        pt_data[3*i+2] = 1;
    }

    return 0;
}

int edge_data_init() {
    int i;

    for (i = 0; i < NEDGES; i++) {
        edge_data[i] = 1;
    }

    return 0;
}

__global__ void edge_gather(float* pt_data, float* edge_data,
        struct graph* gr, int nedges) {

    int i;
    int v0;
    int v1;

    i = blockIdx.x * NTHREADS + threadIdx.x;
    if (i < nedges) {
        v0 = gr->v0[i];
        v1 = gr->v1[i];

        gr->v0_data[i][0] = pt_data[3*v0+0];
        gr->v0_data[i][1] = pt_data[3*v0+1];
        gr->v0_data[i][2] = pt_data[3*v0+2];

        gr->v1_data[i][0] = pt_data[3*v1+0];
        gr->v1_data[i][1] = pt_data[3*v1+1];
        gr->v1_data[i][2] = pt_data[3*v1+2];

        gr->data[i] = edge_data[i];
    }
}

__global__ void edge_compute(struct graph* gr, int nedges) {
    int i;
    float v0_p0, v0_p1, v0_p2;
    float v1_p0, v1_p1, v1_p2;
    float x0, x1, x2;
    float e_data;

    i = blockIdx.x * NTHREADS + threadIdx.x;

    if (i < nedges) {
        v0_p0 = gr->v0_data[i][0];
        v0_p1 = gr->v0_data[i][1];
        v0_p2 = gr->v0_data[i][2];

        v1_p0 = gr->v1_data[i][0];
        v1_p1 = gr->v1_data[i][1];
        v1_p2 = gr->v1_data[i][2];

        e_data = gr->data[i];

        x0 = (v0_p0 + v1_p0) * e_data;
        x1 = (v0_p1 + v1_p1) * e_data;
        x2 = (v0_p2 + v1_p2) * e_data;

        gr->v0_data[i][0] = x0;
        gr->v0_data[i][1] = x1;
        gr->v0_data[i][2] = x2;

        gr->v1_data[i][0] = x0;
        gr->v1_data[i][1] = x1;
        gr->v1_data[i][2] = x2;
    }
}

__global__ void edge_scatter(float* pt_data, struct graph* gr, 
        int nedges) {
    int i;
    int v0;
    int v1;

    i = blockIdx.x * NTHREADS + threadIdx.x;
       
    if (i < nedges) {
        v0 = gr->v0[i];
        v1 = gr->v1[i];

        atomicAdd(&pt_data[3*v0+0], gr->v0_data[i][0]);
        atomicAdd(&pt_data[3*v0+1], gr->v0_data[i][1]);
        atomicAdd(&pt_data[3*v0+2], gr->v0_data[i][2]);

        atomicAdd(&pt_data[3*v1+0], gr->v1_data[i][0]);
        atomicAdd(&pt_data[3*v1+1], gr->v1_data[i][1]);
        atomicAdd(&pt_data[3*v1+2], gr->v1_data[i][2]);
    }
}

int main(int argc, char** argv) {
    int i;
    int rv;
    double time0, time1;
    int c, opt_i;
    int nloops = 0;
    char* gt = "";
    char* fname = "";

    float* d_pt_data;
    struct graph* d_gr;
    float* d_edge_data;

    int nBlocks = (NEDGES / NTHREADS) + 1;

    static struct option long_opts[] = {
        {"help",   no_argument,       0, 0},
        {"type",   required_argument, 0, 0},
        {"nloops", required_argument, 0, 0},
        {"file",   required_argument, 0, 0}
    };

    /* Parse command-line arguments */
    while (1) {
        c = getopt_long(argc, argv, "", 
                long_opts, &opt_i);

        if (c == -1) {
            break;
        }

        if (c == 0) {
            switch (opt_i) {
                case 0:
                    print_help();
                    exit(0);
                case 1:
                    gt = optarg;
                    break;
                case 2:
                    nloops = atoi(optarg);
                    break;
                case 3:
                    fname = optarg;
                    break;
            }
        } else {
            print_help();
            exit(0);
        }
    }

    /* check for errors */
    if (gt == NULL || nloops < 1) {
        print_help();
        exit(0);
    }

    // initialize data structures
    rv = graph_init_soa(gt, NPOINTS, NEDGES, &gr, fname);
    if (rv < 0) {
        printf("Error creating graph. \n");
        exit(0);
    }

    data_init();
    edge_data_init();

    // allocate memory on the GPU
    cudaMalloc((void**) &d_pt_data, NPOINTS * 3 * sizeof(float));
    cudaMalloc((void**) &d_gr, sizeof(struct graph));
    cudaMalloc((void**) &d_edge_data, NEDGES * sizeof(float));

    // loop
    time0 = timer();
    for (i = 0; i < nloops; i++) {

        /* 
         * Edge Gather
         */
        // copy over 
        cudaMemcpy(d_pt_data, pt_data, NPOINTS * 3 * sizeof(float),
                cudaMemcpyHostToDevice);
        cudaMemcpy(d_gr, &gr, sizeof(struct graph),
                cudaMemcpyHostToDevice);
        cudaMemcpy(d_edge_data, edge_data, NEDGES * sizeof(float),
                cudaMemcpyHostToDevice);

        // invoke kernel
        edge_gather<<<nBlocks,NTHREADS>>>(d_pt_data, d_edge_data, d_gr, NEDGES);

        // copy back
        cudaMemcpy(&gr, d_gr, sizeof(struct graph),
                cudaMemcpyDeviceToHost);

        /*
         * Edge Compute
         */
        // copy over
        cudaMemcpy(d_gr, &gr, sizeof(struct graph),
                cudaMemcpyHostToDevice);

        // call kernel
        edge_compute<<<nBlocks,NTHREADS>>>(d_gr, NEDGES);
        
        // copy back
        cudaMemcpy(&gr, d_gr, sizeof(struct graph),
                cudaMemcpyDeviceToHost);

        /* 
         * Edge Scatter
         */
        // copy over 
        cudaMemcpy(d_pt_data, pt_data, NPOINTS * 3 * sizeof(float),
                cudaMemcpyHostToDevice);
        cudaMemcpy(d_gr, &gr, sizeof(struct graph),
                cudaMemcpyHostToDevice);

        // call kernel
        edge_scatter<<<nBlocks,NTHREADS>>>(d_pt_data, d_gr, NEDGES);
        
        // copy back
        cudaMemcpy(pt_data, d_pt_data, NPOINTS * 3 * sizeof(float),
                cudaMemcpyDeviceToHost);

    }
    time1 = timer();

    // free memory
    cudaFree(d_pt_data);
    cudaFree(d_gr);
    cudaFree(d_edge_data);

    // print results
    for (i = 0; i < 10; i++) {
        printf("%i : %f %f %f \n", i, pt_data[3*i+0], 
                pt_data[3*i+1], pt_data[3*i+2]);
    }

    printf("Time: %f s \n", (time1 - time0) / ((float) nloops));

    return 0;
}
