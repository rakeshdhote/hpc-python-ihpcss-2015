
import sys
import itertools as it
from time import time

from libc.math cimport fabs, fmax

import numpy as np
cimport numpy as np

from mpi4py import MPI
from mpi4py cimport MPI
from mpi4py.mpi_c cimport *

# cdef inline debug_array(np.ndarray[double, ndim=2] x, MPI_Comm comm):
#     cdef int rank, size
#     cdef int garbage
#     cdef MPI_Status stat
# 
#     MPI_Comm_size(comm, &size)
#     MPI_Comm_rank(comm, &rank)
# 
#     cdef unsigned int i
# 
#     for i in range(size):
#         MPI_Barrier(comm)
#         if rank == i:
#             if rank == 0:
#                 print
#                 print '='*20
#                 print
# 
#             print x
# 
#             if rank == size - 1:
#                 print
#                 print '='*20
#                 print
# 
#             sys.stdout.flush()

def main():
    cdef unsigned int COLUMNS = 1000
    cdef unsigned int ROWS = 1000
    # COLUMNS = 10
    # ROWS = 10
    cdef unsigned int COLUMNS_P1 = COLUMNS + 1
    cdef unsigned int ROWS_P1 = ROWS + 1
    cdef unsigned int COLUMNS_P2 = COLUMNS + 2
    cdef unsigned int ROWS_P2 = ROWS + 2

    cdef unsigned int i, j

    cdef MPI_Comm comm = MPI_COMM_WORLD

    cdef int rank, size
    MPI_Comm_size(comm, &size)
    MPI_Comm_rank(comm, &rank)

    cdef unsigned int START_ROW = (ROWS*rank)//size
    cdef unsigned int END_ROW = (ROWS*(rank + 1))//size
    cdef unsigned int LOCAL_ROWS = END_ROW - START_ROW

    cdef double MAX_TEMP_ERROR = 0.01

    shape = (LOCAL_ROWS + 2, COLUMNS + 2)

    cdef unsigned int iteration = 1

    cdef double local_dt, global_dt = 1.1*MAX_TEMP_ERROR

    cdef int max_iterations
    if rank == 0:
        max_iterations = <int>int(
            raw_input('Maximum iterations [100-4000]?\n'
        ))

    MPI_Bcast(&max_iterations, 1, MPI_INT, 0, comm)

    cdef double start_time
    if rank == 0:
        start_time = time()

    # initialize
    cdef np.ndarray[double, ndim=2] Temperature_last = np.zeros(shape)
    cdef np.ndarray[double, ndim=2] Temperature = (
        np.empty_like(Temperature_last)
    )

    cdef MPI_Status stat

    # not necessary -- arrays already initialized to 0.0
    Temperature_last[:, 0] = 0.0

    cdef unsigned int start_index = 1
    if rank == 0:
        start_index = 0

    for i in xrange(start_index, LOCAL_ROWS + 1):
        Temperature_last[i, COLUMNS_P1] = (100.0/ROWS)*(i + START_ROW)

    # not necessary -- arrays already initialized to 0.0
    # Temperature_last[0, :] = 0.0

    if rank == size - 1:
        for j in xrange(COLUMNS_P2):
            Temperature_last[LOCAL_ROWS + 1, j] = (100.0/COLUMNS)*j

    cdef MPI_Request top_send_request, bottom_send_request

    # do until error is minimal or until max steps
    while ( global_dt > MAX_TEMP_ERROR and iteration <= max_iterations ):
        # 1D ring exchange
        if rank != 0:
            MPI_Isend(
                &Temperature_last[1, 0],
                COLUMNS_P2, MPI_DOUBLE,
                rank - 1, 0, comm,
                &top_send_request
            )

        if rank != size - 1:
            MPI_Isend(
                &Temperature_last[LOCAL_ROWS, 0],
                COLUMNS_P2, MPI_DOUBLE,
                rank + 1, 0, comm,
                &bottom_send_request
            )

        if rank != 0:
            MPI_Recv(
                &Temperature_last[0, 0],
                COLUMNS_P2, MPI_DOUBLE,
                rank - 1, 0, comm,
                &stat
            )

        if rank != size - 1:
            MPI_Recv(
                &Temperature_last[LOCAL_ROWS + 1, 0],
                COLUMNS_P2, MPI_DOUBLE,
                rank + 1, 0, comm,
                &stat
            )

        local_dt = 0.0

        # main calculation: average my four neighbors
        for i in xrange(1, LOCAL_ROWS + 1):
            for j in xrange(1, COLUMNS_P1):
                Temperature[i, j] = 0.25*(
                    Temperature_last[i+1, j  ] +
                    Temperature_last[i-1, j  ] +
                    Temperature_last[i  , j+1] +
                    Temperature_last[i  , j-1]
                )

                local_dt = fmax(
                    local_dt,
                    fabs(Temperature[i, j] - Temperature_last[i, j]
                ))

        # the fact that mpi4py on bw doesn't have Iallreduce makes me sad :(
        MPI_Allreduce(&local_dt, &global_dt, 1, MPI_DOUBLE, MPI_MAX, comm)

        # copy grid to old grid for next iteration
        for i in range(1, LOCAL_ROWS + 1):
            for j in range(1, COLUMNS_P1):
                Temperature_last[i, j] = Temperature[i, j]

        # periodically print test values
        if iteration % 100 == 0:
            # track progress
            gather_data = []
            for i in range(ROWS - 5, ROWS + 1):
                if (
                    (START_ROW <= i and i < END_ROW) or
                    (i == END_ROW and END_ROW == ROWS and rank == size - 1)
                ):
                    gather_data.append((
                        i, Temperature[i - START_ROW, i]
                    ))

            gather_data = MPI.COMM_WORLD.gather(gather_data, root=0)

            if rank == 0:
                gather_data = it.chain.from_iterable(gather_data)

                print('---------- Iteration number: %d ------------' % iteration)
                for _i, value in gather_data:
                    sys.stdout.write('[%d,%d]: %5.2f  ' % (_i, _i, value))

                sys.stdout.write('\n')
                sys.stdout.flush()

        iteration += 1

        if rank != 0: MPI_Wait(&top_send_request, &stat)
        if rank != size - 1: MPI_Wait(&bottom_send_request, &stat)

    cdef double stop_time, elapsed_time
    if rank == 0:
        stop_time = time()
        elapsed_time = stop_time - start_time

        print('\nMax error at iteration %d was %f' % (iteration - 1, global_dt))
        print('Total time was %f seconds.\n' % elapsed_time)

if __name__ == '__main__':
    main()

