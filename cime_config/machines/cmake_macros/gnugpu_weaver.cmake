if (NOT DEBUG)
  string(APPEND CFLAGS " -O2")
  string(APPEND FFLAGS " -O2")
endif()
if (COMP_NAME STREQUAL gptl)
  string(APPEND CPPDEFS " -DHAVE_SLASHPROC")
endif()
string(APPEND CPPDEFS " -DTHRUST_IGNORE_CUB_VERSION_CHECK")
string(APPEND CXX_LIBS " -lstdc++")
set(MPICXX "mpiCC")
set(NETCDF_C_PATH "/ascldap/users/projects/e3sm/scream/libs/netcdf-c/install/weaver/gcc/8.5.0/cuda/10.1.105")
set(NETCDF_FORTRAN_PATH "/ascldap/users/projects/e3sm/scream/libs/netcdf-fortran/install/weaver/gcc/8.5.0/cuda/10.1.105")
set(PNETCDF_PATH "/ascldap/users/projects/e3sm/scream/libs/pnetcdf/install/weaver/gcc/8.5.0/cuda/10.1.105")
set(HDF5_PATH "")
#string(APPEND CUDA_FLAGS " -O3 -arch sm_70 --use_fast_math")
set(USE_CUDA "TRUE")

if (NOT MPILIB STREQUAL mpi-serial)
  string(APPEND SLIBS " -L${PNETCDF_PATH}/lib -lpnetcdf -L${NETCDF_C_PATH}/lib -lnetcdf -L${NETCDF_FORTRAN_PATH}/lib -lnetcdff")
endif()