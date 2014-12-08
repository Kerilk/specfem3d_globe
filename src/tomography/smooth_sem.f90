!=====================================================================
!
!          S p e c f e m 3 D  G l o b e  V e r s i o n  6 . 0
!          --------------------------------------------------
!
!     Main historical authors: Dimitri Komatitsch and Jeroen Tromp
!                        Princeton University, USA
!                and CNRS / University of Marseille, France
!                 (there are currently many more authors!)
! (c) Princeton University and CNRS / University of Marseille, April 2014
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 2 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
!=====================================================================

! smooth_sem_globe
!
! this program can be used for smoothing a (summed) event kernel,
! where it smooths files with a given input kernel name:
!
! Usage:
!   ./xsmooth_sem sigma_h(km) sigma_v(km) kernel_file_name scratch_file_dir topo_dir
!   e.g.
!   ./xsmooth_sem 160 10 bulk_c_kernel OUTPUT_SUM/ topo/
!
! where:
!   sigma_h                - gaussian width for horizontal smoothing (in km)
!   sigma_v                - gaussian width for vertical smoothing (in km)
!   kernel_file_name       - takes file with this kernel name,
!                                      e.g. "bulk_c_kernel"
!   scratch_file_dir       - directory containing kernel files,
!                                      e.g. proc***_reg1_bulk_c_kernel.bin
!   topo_dir               - directory containing mesh topo files:
!                                      e.g. proc***_solver_data.bin
! outputs:
!    puts the resulting, smoothed kernel files into the same directory as scratch_file_dir/
!    with a file ending "proc***_kernel_smooth.bin"

program smooth_sem_globe

! this is the embarassingly-parallel program that smooths any specfem function (primarily the kernels)
! that has the dimension of (NGLLX,NGLLY,NGLLZ,NSPEC_CRUST_MANTLE)
!
! notice that it uses the constants_globe.h and precision_globe.h files
! from the original SPECFEM3D_GLOBE package, and the
! values_from_mesher_globe.h file from the output of the mesher (or create_header_file),
! therefore, you need to compile it for your specific case
!
! NOTE:  smoothing can be different in radial & horizontal directions; mesh is in spherical geometry.
!              algorithm uses vector components in radial/horizontal direction

  use constants,only: CUSTOM_REAL,NGLLX,NGLLY,NGLLZ,NDIM,NX_BATHY,NY_BATHY,IIN,IOUT, &
    GAUSSALPHA,GAUSSBETA,PI,TWO_PI,R_EARTH_KM,MAX_STRING_LEN,DEGREES_TO_RADIANS,SIZE_INTEGER

  use kdtree_search

  implicit none

  include 'OUTPUT_FILES/values_from_mesher.h'

  ! copy from static compilation (depends on Par_file values)
  integer, parameter :: NPROC_XI  = NPROC_XI_VAL
  integer, parameter :: NPROC_ETA = NPROC_ETA_VAL
  integer, parameter :: NCHUNKS   = NCHUNKS_VAL

  !takes region 1 kernels
  integer, parameter :: NSPEC_AB = NSPEC_CRUST_MANTLE
  integer, parameter :: NGLOB_AB = NGLOB_CRUST_MANTLE

  ! only include the neighboring 3 x 3 slices
  integer, parameter :: NSLICES = 3
  integer ,parameter :: NSLICES2 = NSLICES * NSLICES

  integer :: islice(NSLICES2), islice0(NSLICES2)

  integer, dimension(NGLLX,NGLLY,NGLLZ,NSPEC_AB) :: ibool
  integer, dimension(NSPEC_AB) :: idoubling
  logical, dimension(NSPEC_AB) :: ispec_is_tiso

  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC_AB) :: kernel, kernel_smooth
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC_AB) :: tk, bk, jacobian
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC_AB) :: xx0, yy0, zz0, xx, yy, zz

  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC_AB) :: &
    xix,xiy,xiz,etax,etay,etaz,gammax,gammay,gammaz

  real(kind=CUSTOM_REAL), dimension(NGLOB_AB) :: xstore, ystore, zstore
  real(kind=CUSTOM_REAL), dimension(NSPEC_AB) :: cx0, cy0, cz0, cx, cy, cz

  real(kind=CUSTOM_REAL) :: xixl,xiyl,xizl,etaxl,etayl,etazl,gammaxl,gammayl,gammazl,jacobianl
  real(kind=CUSTOM_REAL) :: sigma_h, sigma_h2, sigma_h3, sigma_v, sigma_v2, sigma_v3
  real(kind=CUSTOM_REAL) :: x0, y0, z0, norm, norm_h, norm_v, element_size_m, max_old, max_new

  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ) :: exp_val
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ) :: factor

  integer :: sizeprocs,ier,myrank,ichunk, ixi, ieta, iglob,nums,ival
  integer :: i,j,k,ispec,iproc,ispec2,inum

  character(len=MAX_STRING_LEN) :: arg(5)
  character(len=MAX_STRING_LEN) :: kernel_filename, topo_dir, scratch_file_dir
  character(len=MAX_STRING_LEN) :: prname_lp
  character(len=MAX_STRING_LEN) :: local_data_file

  character(len=MAX_STRING_LEN) ::  ks_file
  character(len=20) ::  reg_name

  ! Gauss-Lobatto-Legendre points of integration and weights
  double precision, dimension(NGLLX) :: xigll, wxgll
  double precision, dimension(NGLLY) :: yigll, wygll
  double precision, dimension(NGLLZ) :: zigll, wzgll

  ! array with all the weights in the cube
  double precision, dimension(NGLLX,NGLLY,NGLLZ) :: wgll_cube

  real(kind=CUSTOM_REAL) :: dist_h,dist_v
  real(kind=CUSTOM_REAL) :: element_size
  real(kind=CUSTOM_REAL) :: ANGULAR_WIDTH_XI_RAD,ANGULAR_WIDTH_ETA_RAD

  ! search elements
  integer :: ielem,num_elem_local

  ! tree nodes search
  double precision,dimension(3) :: xyz_target
  double precision :: r_search,r_search_dist_v,r_search_dist_h

  ! debugging
  integer, dimension(:),allocatable :: ispec_flag
  real(kind=CUSTOM_REAL), dimension(:,:,:,:),allocatable :: tmp_bk
  character(len=MAX_STRING_LEN) :: filename

  ! timing
  double precision :: time_start
  double precision :: tCPU
  double precision, external :: wtime

  !------------------------------------------------------------------------------------------
  ! USER PARAMETERS

  ! number of steps to reach 100 percent, i.e. 10 outputs info for every 10 percent
  integer,parameter :: NSTEP_PERCENT_INFO = 10

  ! brute-force search for neighboring elements, if set to .false. a kd-tree search will be used
  logical,parameter :: DO_BRUTE_FORCE_SEARCH = .false.

  ! kd-tree search uses either a spherical or ellipsoid search
  logical,parameter :: DO_SEARCH_ELLIP = .true.

  ! debugging
  logical, parameter :: DEBUG = .false.
  ! boundary point: 910, interior point: 2382
  integer ,parameter :: tmp_ispec_dbg = 10

  !------------------------------------------------------------------------------------------

  ! ============ program starts here =====================

  ! initialize the MPI communicator and start the NPROCTOT MPI processes
  call init_mpi()
  call world_size(sizeprocs)
  call world_rank(myrank)

  if (myrank == 0) print*,"smooth_sem:"
  call synchronize_all()

  ! reads arguments
  do i = 1, 5
    call get_command_argument(i,arg(i))
    if (i <= 5 .and. trim(arg(i)) == '') then
      if (myrank == 0 ) then
        print *, 'Usage: '
        print *, '        xsmooth_sem sigma_h sigma_v kernel_file_name scratch_file_dir/ topo_dir/'
        print *
        print *, 'with '
        print *, ' sigma_h                - gaussian width for horizontal smoothing (in km)'
        print *, ' sigma_v                - gaussian width for vertical smoothing (in km)'
        print *, ' kernel_file_name       - takes file with this kernel name'
        print *, ' scratch_file_dir       - directory containing kernel files'
        print *, '                            e.g. proc***_reg1_bulk_c_kernel.bin'
        print *, ' topo_dir               - directory containing mesh topo files:'
        print *, '                            e.g. proc***_solver_data.bin'
        print *
        print *, ' possible kernel_file_names are: '
        print *, '   "alpha_kernel", "beta_kernel", .., "rho_vp", "rho_vs", "kappastore", "mustore", etc.'
        print *
        print *, '   that are stored in the local directory scratch_file_dir/ '
        print *, '   as real(kind=CUSTOM_REAL) filename(NGLLX,NGLLY,NGLLZ,NSPEC_AB) in filename.bin'
        print *
        print *, ' outputs smoothed files to scratch_file_dir/ '
        print *
      endif
      call synchronize_all()
      stop ' Reenter command line options'
    endif
  enddo

  ! gets arguments
  read(arg(1),*) sigma_h
  read(arg(2),*) sigma_v
  kernel_filename = arg(3)
  scratch_file_dir= arg(4)
  topo_dir = arg(5)

  ! checks if basin code or global code: global code uses nchunks /= 0
  if (NCHUNKS == 0) stop 'Error nchunks'
  if (sizeprocs /= NPROCTOT_VAL) call exit_mpi(myrank,'Error total number of slices')

  ! crust/mantle region smoothing only
  reg_name='_reg1_'

  ! estimates mesh element size
  ! note: this estimation is for global meshes valid only
  ! see values_from_mesher.h:
  !   average size of a spectral element in km = ...
  !   e.g. nproc 12x12, nex 192: element_size = 52.122262
  if (NCHUNKS_VAL == 6 ) then
    element_size = TWO_PI / dble(4) * R_EARTH_KM / dble(NEX_XI_VAL)
  else
    ANGULAR_WIDTH_XI_RAD = ANGULAR_WIDTH_XI_IN_DEGREES_VAL * DEGREES_TO_RADIANS
    ANGULAR_WIDTH_ETA_RAD = ANGULAR_WIDTH_ETA_IN_DEGREES_VAL * DEGREES_TO_RADIANS
    element_size = max( ANGULAR_WIDTH_XI_RAD/NEX_XI_VAL,ANGULAR_WIDTH_ETA_RAD/NEX_ETA_VAL ) * R_EARTH_KM
  endif

  ! user output
  if (myrank == 0) then
    print*,"defaults:"
    print*,"  NPROC_XI , NPROC_ETA        : ",NPROC_XI,NPROC_ETA
    print*,"  NCHUNKS                     : ",NCHUNKS
    print*,"  element size on surface (km): ",element_size
    print*
    print*,"  smoothing sigma_h , sigma_v (km)                : ",sigma_h,sigma_v
    ! scalelength: approximately S ~ sigma * sqrt(8.0) for a gaussian smoothing
    print*,"  smoothing scalelengths horizontal, vertical (km): ",sigma_h*sqrt(8.0),sigma_v*sqrt(8.0)
    print*
    print*,"  data name      : ",trim(kernel_filename)
    print*,"  input file dir : ",trim(scratch_file_dir)
    print*,"  topo dir       : ",trim(topo_dir)
    print*
    print*,"number of elements per slice: ",NSPEC_AB
    print*
  endif
  ! synchronizes
  call synchronize_all()

  ! initializes lengths (non-dimensionalizes)
  element_size_m = element_size / R_EARTH_KM ! e.g. 9 km on the surface, 36 km at CMB

  sigma_h = sigma_h / R_EARTH_KM ! scale
  sigma_v = sigma_v / R_EARTH_KM ! scale

  sigma_h2 = 2.0 * sigma_h ** 2  ! factor two for gaussian distribution with standard variance sigma
  sigma_v2 = 2.0 * sigma_v ** 2

  ! checks
  if (sigma_h2 < 1.e-18) stop 'Error sigma_h2 zero, must be non-zero'
  if (sigma_v2 < 1.e-18) stop 'Error sigma_v2 zero, must be non-zero'

  ! search radius
  sigma_h3 = 3.0  * sigma_h + element_size_m
  sigma_v3 = 3.0  * sigma_v + element_size_m

  if (.not. DO_BRUTE_FORCE_SEARCH) then
    ! kd-tree search uses a slightly larger constant search radius
    r_search = max( 1.1d0 * sigma_h3, 1.1d0 * sigma_v3 )
    r_search_dist_v = sigma_v3
    r_search_dist_h = sigma_h3
  else
    r_search = 0.d0
  endif

  ! theoretic normal value
  ! (see integral over -inf to +inf of exp[- x*x/(2*sigma) ] = sigma * sqrt(2*pi) )

! note: smoothing is using a gaussian (ellipsoid for sigma_h /= sigma_v),
!          but in spherical coordinates, we use horizontal distance as epicentral distance
!          and vertical distance as radial distance?

! not squared since epicentral distance is taken? values from bk seem to be closer to squared ones...
  !norm_h = sqrt(2.0*PI) * sigma_h
  norm_h = 2.0*PI*sigma_h**2
  norm_v = sqrt(2.0*PI) * sigma_v
  norm   = norm_h * norm_v
  !norm = (sqrt(2.0*PI) * sigma) ** 3 ! for sigma_h = sigma_v = sigma

  ! GLL points weights
  call zwgljd(xigll,wxgll,NGLLX,GAUSSALPHA,GAUSSBETA)
  call zwgljd(yigll,wygll,NGLLY,GAUSSALPHA,GAUSSBETA)
  call zwgljd(zigll,wzgll,NGLLZ,GAUSSALPHA,GAUSSBETA)
  do k=1,NGLLZ
    do j=1,NGLLY
      do i=1,NGLLX
        wgll_cube(i,j,k) = wxgll(i)*wygll(j)*wzgll(k)
      enddo
    enddo
  enddo

  ! ---- figure out the neighboring 8 or 7 slices: (ichunk,ixi,ieta) index start at 0------
  ichunk = myrank / (NPROC_XI * NPROC_ETA)
  ieta = (myrank - ichunk * NPROC_XI * NPROC_ETA) / NPROC_XI
  ixi = myrank - ichunk * NPROC_XI * NPROC_ETA - ieta * NPROC_XI

  ! get the neighboring slices:
  call get_all_eight_slices(ichunk,ixi,ieta,&
                            islice0(1),islice0(2),islice0(3),islice0(4),islice0(5),islice0(6),islice0(7),islice0(8),&
                            NPROC_XI,NPROC_ETA)

  ! remove the repeated slices (only 8 for corner slices in global case)
  islice(1) = myrank; j = 1
  do i = 1, 8
    if (.not. any(islice(1:i) == islice0(i)) .and. islice0(i) < sizeprocs) then
      j = j + 1
      islice(j) = islice0(i)
    endif
  enddo
  nums = j

  if (myrank == 0) then
    print *,'slices:',nums
    print *,'  rank:',myrank,'  smoothing slices'
    print *,'  ',islice(1:nums)
    print *
  endif

  ! read in the topology files of the current and neighboring slices
  ! point locations
  write(prname_lp,'(a,i6.6,a)') trim(topo_dir)//'/proc',myrank,trim(reg_name)//'solver_data.bin'
  open(IIN,file=trim(prname_lp),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening file: ',trim(prname_lp)
    call exit_mpi(myrank,'Error opening solver_data.bin file')
  endif

  ! checks nspec
  read(IIN) ival
  if (ival /= NSPEC_AB) call exit_mpi(myrank,'Error invalid nspec value in solver_data.bin')

  ! checks nglob
  read(IIN) ival
  if (ival /= NGLOB_AB) call exit_mpi(myrank,'Error invalid nglob value in solver_data.bin')

  ! node locations
  read(IIN) xstore
  read(IIN) ystore
  read(IIN) zstore

  read(IIN) ibool
  read(IIN) idoubling
  read(IIN) ispec_is_tiso

  read(IIN) xix
  read(IIN) xiy
  read(IIN) xiz
  read(IIN) etax
  read(IIN) etay
  read(IIN) etaz
  read(IIN) gammax
  read(IIN) gammay
  read(IIN) gammaz
  close(IIN)

  ! synchronizes
  call synchronize_all()

  ! get the location of the center of the elements
  do ispec = 1, NSPEC_AB
    do k = 1, NGLLZ
      do j = 1, NGLLY
        do i = 1, NGLLX
          iglob = ibool(i,j,k,ispec)
          xx0(i,j,k,ispec) = xstore(iglob)
          yy0(i,j,k,ispec) = ystore(iglob)
          zz0(i,j,k,ispec) = zstore(iglob)

          ! build jacobian
          ! get derivatives of ux, uy and uz with respect to x, y and z
          xixl = xix(i,j,k,ispec)
          xiyl = xiy(i,j,k,ispec)
          xizl = xiz(i,j,k,ispec)
          etaxl = etax(i,j,k,ispec)
          etayl = etay(i,j,k,ispec)
          etazl = etaz(i,j,k,ispec)
          gammaxl = gammax(i,j,k,ispec)
          gammayl = gammay(i,j,k,ispec)
          gammazl = gammaz(i,j,k,ispec)
          ! compute the jacobian
          jacobianl = 1._CUSTOM_REAL / (xixl*(etayl*gammazl-etazl*gammayl) &
                        - xiyl*(etaxl*gammazl-etazl*gammaxl) &
                        + xizl*(etaxl*gammayl-etayl*gammaxl))

          jacobian(i,j,k,ispec) = jacobianl
        enddo
      enddo
    enddo
    cx0(ispec) = (xx0(1,1,1,ispec) + xx0(NGLLX,NGLLY,NGLLZ,ispec)) * 0.5_CUSTOM_REAL
    cy0(ispec) = (yy0(1,1,1,ispec) + yy0(NGLLX,NGLLY,NGLLZ,ispec)) * 0.5_CUSTOM_REAL
    cz0(ispec) = (zz0(1,1,1,ispec) + zz0(NGLLX,NGLLY,NGLLZ,ispec)) * 0.5_CUSTOM_REAL
  enddo

  ! element search
  if (.not. DO_BRUTE_FORCE_SEARCH) then
    ! search by kd-tree
    ! user output
    if (myrank == 0) then
      print*,'using kd-tree search:'
      if (DO_SEARCH_ELLIP) then
        print*,'  search radius horizontal: ',r_search_dist_h * R_EARTH_KM,'km'
        print*,'  search radius vertical  : ',r_search_dist_v * R_EARTH_KM,'km'
      else
        print*,'  search sphere radius: ',r_search * R_EARTH_KM,'km'
      endif
      print*
    endif

    ! set number of tree nodes
    kdtree_num_nodes = NSPEC_AB

    ! checks
    if (kdtree_num_nodes <= 0) stop 'Error number of kd-tree nodes is zero, please check NSPEC_AB'

    ! allocates tree arrays
    allocate(kdtree_nodes_location(NDIM,kdtree_num_nodes),stat=ier)
    if (ier /= 0) stop 'Error allocating kdtree_nodes_location arrays'
    allocate(kdtree_nodes_index(kdtree_num_nodes),stat=ier)
    if (ier /= 0) stop 'Error allocating kdtree_nodes_index arrays'

    ! tree verbosity
    if (myrank == 0) call kdtree_set_verbose()

  else
    ! brute-force search
    ! user output
    if (myrank == 0) then
      print*,'using brute-force search:'
      print*,'  search radius horizontal: ',sigma_h3 * R_EARTH_KM,'km'
      print*,'  search radius vertical  : ',sigma_v3 * R_EARTH_KM,'km'
      print*
    endif
  endif

  ! synchronizes
  call synchronize_all()

  if (myrank == 0) print*, 'start looping over elements and points for smoothing ...'

  ! synchronizes
  call synchronize_all()

  tk(:,:,:,:) = 0.0_CUSTOM_REAL
  bk(:,:,:,:) = 0.0_CUSTOM_REAL

  ! loop over all slices
  do inum = 1, nums

    ! timing
    time_start = wtime()

    iproc = islice(inum)

    if (myrank == 0) print*,'  reading slice:',iproc

    ! debugging
    if (DEBUG .and. myrank == 0) then
      allocate(tmp_bk(NGLLX,NGLLY,NGLLZ,NSPEC_AB),stat=ier)
      if (ier /= 0) stop 'Error allocating array tmp_bk'
      tmp_bk(:,:,:,:) = 0.0_CUSTOM_REAL
    endif

    ! neighbor database file
    write(prname_lp,'(a,i6.6,a)') trim(topo_dir)//'/proc',iproc,trim(reg_name)//'solver_data.bin'

    ! read in the topology, kernel files, calculate center of elements
    ! point locations
    ! given in cartesian coordinates
    open(IIN,file=trim(prname_lp),status='old',form='unformatted',iostat=ier)
    if (ier /= 0) then
      print*,'Error could not open database file: ',trim(prname_lp)
      call exit_mpi(myrank,'Error opening slices in solver_data.bin file')
    endif

    read(IIN) ival  ! nspec
    read(IIN) ival  ! nglob
    read(IIN) xstore
    read(IIN) ystore
    read(IIN) zstore

    read(IIN) ibool
    read(IIN) idoubling
    read(IIN) ispec_is_tiso

    read(IIN) xix
    read(IIN) xiy
    read(IIN) xiz
    read(IIN) etax
    read(IIN) etay
    read(IIN) etaz
    read(IIN) gammax
    read(IIN) gammay
    read(IIN) gammaz
    close(IIN)

    ! get the location of the center of the elements
    do ispec = 1, NSPEC_AB
      do k = 1, NGLLZ
        do j = 1, NGLLY
          do i = 1, NGLLX
            iglob = ibool(i,j,k,ispec)
            xx(i,j,k,ispec) = xstore(iglob)
            yy(i,j,k,ispec) = ystore(iglob)
            zz(i,j,k,ispec) = zstore(iglob)

            ! build jacobian
            ! get derivatives of ux, uy and uz with respect to x, y and z
            xixl = xix(i,j,k,ispec)
            xiyl = xiy(i,j,k,ispec)
            xizl = xiz(i,j,k,ispec)
            etaxl = etax(i,j,k,ispec)
            etayl = etay(i,j,k,ispec)
            etazl = etaz(i,j,k,ispec)
            gammaxl = gammax(i,j,k,ispec)
            gammayl = gammay(i,j,k,ispec)
            gammazl = gammaz(i,j,k,ispec)
            ! compute the jacobian
            jacobianl = 1._CUSTOM_REAL / (xixl*(etayl*gammazl-etazl*gammayl) &
                          - xiyl*(etaxl*gammazl-etazl*gammaxl) &
                          + xizl*(etaxl*gammayl-etayl*gammaxl))
            jacobian(i,j,k,ispec) = jacobianl
          enddo
        enddo
      enddo
      ! calculate element center location
      cx(ispec) = (xx(1,1,1,ispec) + xx(NGLLX,NGLLY,NGLLZ,ispec)) * 0.5_CUSTOM_REAL
      cy(ispec) = (yy(1,1,1,ispec) + yy(NGLLX,NGLLY,NGLLZ,ispec)) * 0.5_CUSTOM_REAL
      cz(ispec) = (zz(1,1,1,ispec) + zz(NGLLX,NGLLY,NGLLZ,ispec)) * 0.5_CUSTOM_REAL
    enddo

    ! user output
    if (myrank == 0) print*,'  reading data file:',iproc,trim(kernel_filename)

    ! data file
    write(local_data_file,'(a,i6.6,a)') &
      trim(scratch_file_dir)//'/proc',iproc,trim(reg_name)//trim(kernel_filename)//'.bin'

    open(IIN,file=trim(local_data_file),status='old',form='unformatted',iostat=ier)
    if (ier /= 0) then
      print *,'Error opening data file: ',trim(local_data_file)
      call exit_mpi(myrank,'Error opening data file')
    endif

    read(IIN) kernel
    close(IIN)
    ! get the global maximum value of the original kernel file
    if (iproc == myrank) max_old = maxval(abs(kernel))

    if (myrank == 0) print*

    ! search setup
    if (.not. DO_BRUTE_FORCE_SEARCH) then
      ! search by kd-tree

      ! prepares search arrays, each element takes its midpoint for tree search
      kdtree_nodes_index(:) = 0
      kdtree_nodes_location(:,:) = 0.0

      ! fills kd-tree arrays
      do ispec = 1,NSPEC_AB
        ! adds node index ( index points to same ispec for all internal gll points)
        kdtree_nodes_index(ispec) = ispec

        ! adds node location
        kdtree_nodes_location(1,ispec) = cx(ispec)
        kdtree_nodes_location(2,ispec) = cy(ispec)
        kdtree_nodes_location(3,ispec) = cz(ispec)
      enddo

      ! creates kd-tree for searching
      call kdtree_setup()
    endif

    ! loops over elements to be smoothed in the current slice
    do ispec = 1, NSPEC_AB

      ! user info about progress
      if (myrank == 0) then
        tCPU = wtime() - time_start
        if (mod(ispec-1,NSPEC_AB/NSTEP_PERCENT_INFO) == 0 .and. ispec < (NSPEC_AB - 0.5*NSPEC_AB/NSTEP_PERCENT_INFO)) then
          print*,'    ',int((ispec-1) / (NSPEC_AB/NSTEP_PERCENT_INFO)) * (100.0 / NSTEP_PERCENT_INFO), &
                 ' % elements done - Elapsed time in seconds = ',tCPU
        endif
        if (ispec == NSPEC_AB) then
          print*,'    ',100.0,' % elements done - Elapsed time in seconds = ',tCPU
        endif
      endif

      ! initializes 
      num_elem_local = 0

      ! sets number of elements to loop over
      if (.not. DO_BRUTE_FORCE_SEARCH) then
        xyz_target(1) = cx0(ispec)
        xyz_target(2) = cy0(ispec)
        xyz_target(3) = cz0(ispec)

        ! counts nearest neighbors
        if (DO_SEARCH_ELLIP) then
          ! (within ellipsoid)
          call kdtree_count_nearest_n_neighbors_ellip(xyz_target,r_search_dist_v,r_search_dist_h,num_elem_local)
        else
          ! (within search sphere)
          call kdtree_count_nearest_n_neighbors(xyz_target,r_search,num_elem_local)
        endif

        ! checks that at least a single element was choosen
        if (iproc == myrank) then
          if (num_elem_local < 1) stop 'Error no local search element found'
        endif

        ! sets n-search number of nodes
        kdtree_search_num_nodes = num_elem_local

        ! allocates search array
        if (kdtree_search_num_nodes > 0) then
          allocate(kdtree_search_index(kdtree_search_num_nodes),stat=ier)
          if (ier /= 0) stop 'Error allocating array kdtree_search_index'

          ! finds closest point in target chunk
          if (DO_SEARCH_ELLIP) then
            ! (within ellipsoid)
            call kdtree_get_nearest_n_neighbors_ellip(xyz_target,r_search_dist_v,r_search_dist_h,num_elem_local)
          else
            ! (within search sphere)
            call kdtree_get_nearest_n_neighbors(xyz_target,r_search,num_elem_local)
          endif
        endif

        ! debug output
        if (DEBUG .and. myrank == 0) then
          ! user info
          if (ispec < 10) then
            print*,'  total number of search elements: ',num_elem_local,'ispec',ispec
          endif
          ! file output
          if (ispec == tmp_ispec_dbg) then
            ! outputs search elements with integer flags
            allocate(ispec_flag(NSPEC_AB))
            ispec_flag(:) = 0
            ! debug element (tmp_ispec_dbg)
            do ielem = 1,num_elem_local
              i = kdtree_search_index(ielem)
              ispec_flag(i) = ielem
            enddo
            write(filename,'(a,i4.4,a,i6.6)') trim(scratch_file_dir)//'/search_elem',tmp_ispec_dbg,'_proc',iproc
            call write_VTK_data_elem_i(NSPEC_AB,NGLOB_AB,xstore,ystore,zstore, &
                                       ibool,ispec_flag,filename)
            print*,'file written: ',trim(filename)//'.vtk'
            deallocate(ispec_flag)
          endif
        endif
      else
        ! brute-force search always loops over whole mesh slice
        num_elem_local = NSPEC_AB
      endif

      ! --- only double loop over the elements in the search radius ---
      do ielem = 1, num_elem_local

        if (.not. DO_BRUTE_FORCE_SEARCH) then
          ! kd-tree search elements
          ispec2 = kdtree_search_index(ielem)

          ! (spherical search radius)
          ! calculates horizontal and vertical distance between two element centers
          ! vector approximation
          call get_distance_vec(dist_h,dist_v,cx0(ispec),cy0(ispec),cz0(ispec),&
                                cx(ispec2),cy(ispec2),cz(ispec2))

          ! note: distances and sigmah, sigmav are normalized by R_EARTH_KM

          ! checks distance between centers of elements
          if ( dist_h > sigma_h3 .or. abs(dist_v) > sigma_v3 ) cycle
        else
          ! brute-force search
          ! takes only elements in search radius
          ! calculates horizontal and vertical distance between two element centers
          ispec2 = ielem
          call get_distance_vec(dist_h,dist_v,cx0(ispec),cy0(ispec),cz0(ispec),&
                                cx(ispec2),cy(ispec2),cz(ispec2))

          ! note: distances and sigmah, sigmav are normalized by R_EARTH_KM

          ! checks distance between centers of elements
          if ( dist_h > sigma_h3 .or. abs(dist_v) > sigma_v3 ) cycle
        endif

        ! integration factors:
        ! uses volume assigned to GLL points
        factor(:,:,:) = jacobian(:,:,:,ispec2) * wgll_cube(:,:,:)
        ! no volume
        !factor(:,:,:) = 1.0_CUSTOM_REAL

        ! loop over GLL points of the elements in current slice (ispec)
        do k = 1, NGLLZ
          do j = 1, NGLLY
            do i = 1, NGLLX

              ! reference location
              ! current point (i,j,k,ispec) location, cartesian coordinates
              x0 = xx0(i,j,k,ispec)
              y0 = yy0(i,j,k,ispec)
              z0 = zz0(i,j,k,ispec)

              ! calculate weights based on gaussian smoothing
              call smoothing_weights_vec(x0,y0,z0,sigma_h2,sigma_v2,exp_val,&
                                         xx(:,:,:,ispec2),yy(:,:,:,ispec2),zz(:,:,:,ispec2))

              ! debug
              if (DEBUG .and. myrank == 0) then
                if (i == 3 .and. j == 3 .and. k == 3 .and. ispec == tmp_ispec_dbg) then
                  tmp_bk(:,:,:,ispec2) = exp_val(:,:,:)
                endif
              endif

              ! adds GLL integration weights
              exp_val(:,:,:) = exp_val(:,:,:) * factor(:,:,:)

              ! adds contribution of element ispec2 to smoothed kernel values
              tk(i,j,k,ispec) = tk(i,j,k,ispec) + sum(exp_val(:,:,:) * kernel(:,:,:,ispec2))

              ! normalization, integrated values of gaussian smoothing function
              bk(i,j,k,ispec) = bk(i,j,k,ispec) + sum(exp_val(:,:,:))

              ! checks number
              !if (isNaN(tk(i,j,k,ispec))) then
              !  print*,'Error tk NaN: ',tk(i,j,k,ispec)
              !  print*,'rank:',myrank
              !  print*,'i,j,k,ispec:',i,j,k,ispec
              !  print*,'tk: ',tk(i,j,k,ispec),'bk:',bk(i,j,k,ispec)
              !  print*,'sum exp_val: ',sum(exp_val(:,:,:)),'sum factor:',sum(factor(:,:,:))
              !  print*,'sum kernel:',sum(kernel(:,:,:,ispec2))
              !  call exit_mpi(myrank, 'Error NaN')
              !endif

            enddo
          enddo
        enddo ! (i,j,k)
      enddo ! (ielem)

      ! frees search results
      if (.not. DO_BRUTE_FORCE_SEARCH) then
        if (kdtree_search_num_nodes > 0) then
          deallocate(kdtree_search_index)
          kdtree_search_num_nodes = 0
        endif
      endif

      ! debug output
      if (DEBUG .and. myrank == 0) then
        ! debug element (tmp_ispec_dbg)
        if (ispec == tmp_ispec_dbg) then
          ! outputs gaussian weighting function
          write(filename,'(a,i4.4,a,i6.6)') trim(scratch_file_dir)//'/search_elem',tmp_ispec_dbg,'_gaussian_proc',iproc
          call write_VTK_data_elem_cr(NSPEC_AB,NGLOB_AB,xstore,ystore,zstore, &
                                     ibool,tmp_bk,filename)
          print*,'file written: ',trim(filename)//'.vtk'
        endif
      endif

    enddo   ! (ispec)

    ! debug output
    if (DEBUG .and. myrank == 0) then
      deallocate(tmp_bk)
    endif

    ! deletes search tree nodes
    if (.not. DO_BRUTE_FORCE_SEARCH) then
      call kdtree_delete()
    endif
    if (myrank == 0) print *

  enddo     ! islice

  if (myrank == 0) print *

  ! frees memory
  if (.not. DO_BRUTE_FORCE_SEARCH) then
    deallocate(kdtree_nodes_location)
    deallocate(kdtree_nodes_index)
  endif

  ! synchronizes
  call synchronize_all()

  ! normalizes/scaling factor
  if (myrank == 0) then
    print*, 'Scaling values: min/max = ',minval(bk),maxval(bk)
    print*, '                norm    = ',norm
  endif

  ! compute the smoothed kernel values
  kernel_smooth(:,:,:,:) = 0.0_CUSTOM_REAL
  do ispec = 1, NSPEC_AB
    do k = 1, NGLLZ
      do j = 1, NGLLY
        do i = 1, NGLLX

          ! checks the normalization criterion
          ! e.g. sigma_h 160km, sigma_v 40km:
          !     norm (not squared sigma_h ) ~ 0.001
          !     norm ( squared sigma_h) ~ 6.23 * e-5
          if (abs(bk(i,j,k,ispec) - norm) > 1.e-4 ) then
            print *, 'Problem norm here --- ', myrank, ispec, i, j, k, bk(i,j,k,ispec), norm
            !call exit_mpi(myrank, 'Error computing Gaussian function on the grid')
          endif

          ! avoids division by zero
          !if (bk(i,j,k,ispec) == 0.0_CUSTOM_REAL) bk(i,j,k,ispec) = 1.0_CUSTOM_REAL

          ! normalizes smoothed kernel values by integral value of gaussian weighting
          kernel_smooth(i,j,k,ispec) = tk(i,j,k,ispec) / bk(i,j,k,ispec)

          ! checks number (isNaN check)
          if (kernel_smooth(i,j,k,ispec) /= kernel_smooth(i,j,k,ispec)) then
            print*,'Error kernel_smooth value not a number: ',kernel_smooth(i,j,k,ispec)
            print*,'rank:',myrank
            print*,'i,j,k,ispec:',i,j,k,ispec
            print*,'tk: ',tk(i,j,k,ispec),'bk:',bk(i,j,k,ispec)
            call exit_mpi(myrank, 'Error kernel value is NaN')
          endif
        enddo
      enddo
    enddo
  enddo

  max_new = maxval(abs(kernel_smooth))

  ! file output
  ! smoothed kernel file name
  write(ks_file,'(a,i6.6,a)') trim(scratch_file_dir)//'/proc',myrank, &
                              trim(reg_name)//trim(kernel_filename)//'_smooth.bin'

  open(IOUT,file=trim(ks_file),status='unknown',form='unformatted',iostat=ier)
  if (ier /= 0) call exit_mpi(myrank,'Error opening smoothed kernel file')

  ! Note: output the following instead of kernel_smooth(:,:,:,1:NSPEC_AB) to create files of the same sizes
  write(IOUT) kernel_smooth(:,:,:,:)
  close(IOUT)
  if (myrank == 0) print *,'written: ',trim(ks_file)

  ! synchronizes
  call synchronize_all()

  ! the maximum value for the smoothed kernel
  norm = max_old
  call max_all_cr(norm, max_old)
  norm = max_new
  call max_all_cr(norm, max_new)
  if (myrank == 0) then
    print *
    print *, 'Maximum data value before smoothing = ', max_old
    print *, 'Maximum data value after smoothing  = ', max_new
    print *
  endif

  ! stop all the processes, and exit
  call finalize_mpi()

end program smooth_sem_globe

