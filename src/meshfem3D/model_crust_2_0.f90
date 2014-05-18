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

!--------------------------------------------------------------------------------------------------
! CRUST 2.0 model by Bassin et al. (2000)
!
! C. Bassin, G. Laske, and G. Masters.
! The current limits of resolution for surface wave tomography in North America.
! EOS, 81: F897, 2000.
!
! The 7 crustal layers:
! ====================
! 1) ice
! 2) water
! 3) soft sediments
! 4) hard sediments
! 5) upper crust
! 6) middle crust
! 7) lower crust
! + Parameters VP, VS and rho are given explicitly for these 7 layers as well as the mantle below the Moho.
!
! reads and smooths crust2.0 model
!--------------------------------------------------------------------------------------------------

  module model_crust_2_0_par

  ! crustal_model_constants
  ! crustal model parameters for crust2.0
  integer, parameter :: CRUST_NP = 8
  integer, parameter :: CRUST_NLO = 359
  integer, parameter :: CRUST_NLA = 180

  ! model_crust_variables
  ! Vp, Vs and density
  double precision, dimension(:,:), allocatable :: crust_vp,crust_vs,crust_rho
  character(len=2) :: abbreviation(CRUST_NLA/2,CRUST_NLA)
  character(len=2) :: code(CRUST_NLO)

  ! layer thickness
  double precision, dimension(:,:), allocatable :: crust_thickness

  end module model_crust_2_0_par

!
!--------------------------------------------------------------------------------------------------
!

  subroutine model_crust_2_0_broadcast(myrank)

! standard routine to setup model

  use constants
  use model_crust_2_0_par

  implicit none

  integer :: myrank
  integer :: ier

  ! allocate crustal arrays
  allocate(crust_thickness(CRUST_NP,CRUST_NLO), &
           crust_vp(CRUST_NP,CRUST_NLO), &
           crust_vs(CRUST_NP,CRUST_NLO), &
           crust_rho(CRUST_NP,CRUST_NLO), &
           stat=ier)
  if( ier /= 0 ) call exit_MPI(myrank,'error allocating crustal arrays')

  ! initializes
  crust_vp(:,:) = ZERO
  crust_vs(:,:) = ZERO
  crust_rho(:,:) = ZERO
  crust_thickness(:,:) = ZERO

  ! the variables read are declared and stored in structure model_crust_2_0_par
  if(myrank == 0) call read_crust_2_0_model()

  ! broadcast the information read on the master to the nodes
  call bcast_all_dp(crust_thickness,CRUST_NLO*CRUST_NP)
  call bcast_all_dp(crust_vp,CRUST_NLO*CRUST_NP)
  call bcast_all_dp(crust_vs,CRUST_NLO*CRUST_NP)
  call bcast_all_dp(crust_rho,CRUST_NLO*CRUST_NP)

  call bcast_all_ch_array2(abbreviation,CRUST_NLA/2,CRUST_NLA,2)
  call bcast_all_ch_array(code,CRUST_NLO,2)

  end subroutine model_crust_2_0_broadcast

!
!-------------------------------------------------------------------------------------------------
!

  subroutine model_crust_2_0(lat,lon,x,vp,vs,rho,moho,found_crust,elem_in_crust)

  use constants
  use model_crust_2_0_par

  implicit none

  double precision,intent(in) :: lat,lon,x
  double precision,intent(out) :: vp,vs,rho,moho
  logical,intent(out) :: found_crust
  logical,intent(in) :: elem_in_crust

  ! local parameters
  double precision :: h_sed,h_uc
  double precision :: x3,x4,x5,x6,x7
  double precision :: scaleval
  double precision,dimension(CRUST_NP):: vps,vss,rhos,thicks

  ! initializes
  vp = ZERO
  vs = ZERO
  rho = ZERO
  moho = ZERO

  ! gets smoothed structure
  call crust_2_0_CAPsmoothed(lat,lon,vps,vss,rhos,thicks,abbreviation, &
                        code,crust_thickness,crust_vp,crust_vs,crust_rho)

  ! note: for seismic wave propagation we ignore the water and ice sheets (oceans are re-added later as an ocean load)

  ! whole sediment thickness
  h_sed = thicks(3) + thicks(4)

  ! upper crust thickness (including sediments above)
  h_uc = h_sed + thicks(5)

  ! non-dimensionalization factor
  scaleval = ONE / R_EARTH_KM

  ! non-dimensionalizes thickness (given in km)
  ! upper sediment
  x3 = ONE - thicks(3) * scaleval
  ! all sediments
  x4 = ONE - h_sed * scaleval
  ! upper crust
  x5 = ONE - h_uc * scaleval
  ! middle crust
  x6 = ONE - (h_uc+thicks(6)) * scaleval
  ! lower crust
  x7 = ONE - (h_uc+thicks(6)+thicks(7)) * scaleval

  ! checks moho value
  !moho = h_uc + thicks(6) + thicks(7)
  !if( moho /= thicks(CRUST_NP) ) then
  ! print*,'moho:',moho,thicks(CRUST_NP)
  ! print*,'  lat/lon/x:',lat,lon,x
  !endif

  ! no matter if found_crust is true or false, compute moho thickness
  moho = (h_uc+thicks(6)+thicks(7)) * scaleval

  ! gets corresponding crustal velocities and density
  found_crust = .true.

  ! gets corresponding crustal velocities and density
  if(x > x3 .and. INCLUDE_SEDIMENTS_IN_CRUST ) then
    vp = vps(3)
    vs = vss(3)
    rho = rhos(3)
  else if(x > x4 .and. INCLUDE_SEDIMENTS_IN_CRUST ) then
    vp = vps(4)
    vs = vss(4)
    rho = rhos(4)
  else if(x > x5) then
    vp = vps(5)
    vs = vss(5)
    rho = rhos(5)
  else if(x > x6) then
    vp = vps(6)
    vs = vss(6)
    rho = rhos(6)
  else if(x > x7 .or. elem_in_crust) then
    ! takes lower crustal values only if x is slightly above moho depth or
    ! if elem_in_crust is set
    !
    ! note: it looks like this does distinguish between GLL points at the exact moho boundary,
    !          where the point is on the interface between both,
    !          oceanic elements and mantle elements below
    vp = vps(7)
    vs = vss(7)
    rho = rhos(7)
  else
    ! note: if x is exactly the moho depth this will return false
    found_crust = .false.
  endif

  ! non-dimensionalize
  if (found_crust) then
    scaleval = ONE / ( R_EARTH_KM * dsqrt(PI*GRAV*RHOAV) )
    vp = vp * scaleval
    vs = vs * scaleval
    rho = rho * 1000.0d0 / RHOAV
 endif

 end subroutine model_crust_2_0

!
!-------------------------------------------------------------------------------------------------
!

  subroutine read_crust_2_0_model()

  use constants
  use model_crust_2_0_par

  implicit none

  ! local variables
  integer :: i,ila,icolat,ikey,ier

  double precision :: h_moho_min,h_moho_max

  character(len=150) :: CNtype2, CNtype2_key_modif

  ! user output
  write(IMAIN,*)
  write(IMAIN,*) 'incorporating crustal model: CRUST2.0'
  write(IMAIN,*)

  call get_value_string(CNtype2, 'model.CNtype2', 'DATA/crust2.0/CNtype2.txt')
  open(unit=1,file=CNtype2,status='old',action='read',iostat=ier)
  if ( ier /= 0 ) then
    write(IMAIN,*) 'error opening "', trim(CNtype2), '": ', ier
    call flush_IMAIN()
    ! stop
    call exit_MPI(0,'error model crust2.0')
  endif

  do ila=1,CRUST_NLA/2
    read(1,*) icolat,(abbreviation(ila,i),i=1,CRUST_NLA)
  enddo
  close(1)

  call get_value_string(CNtype2_key_modif, 'model.CNtype2_key_modif', 'DATA/crust2.0/CNtype2_key_modif.txt')
  open(unit=1,file=CNtype2_key_modif,status='old',action='read',iostat=ier)
  if ( ier /= 0 ) then
    write(IMAIN,*) 'error opening "', trim(CNtype2_key_modif), '": ', ier
    call exit_MPI(0,'error model crust2.0')
  endif

  h_moho_min = HUGEVAL
  h_moho_max = -HUGEVAL

  do ikey=1,CRUST_NLO
    read (1,"(a2)") code(ikey)
    read (1,*) (crust_vp(i,ikey),i=1,CRUST_NP)
    read (1,*) (crust_vs(i,ikey),i=1,CRUST_NP)
    read (1,*) (crust_rho(i,ikey),i=1,CRUST_NP)
    read (1,*) (crust_thickness(i,ikey),i=1,CRUST_NP-1),crust_thickness(CRUST_NP,ikey)

    ! limit moho thickness
    if(crust_thickness(CRUST_NP,ikey) > h_moho_max) h_moho_max = crust_thickness(CRUST_NP,ikey)
    if(crust_thickness(CRUST_NP,ikey) < h_moho_min) h_moho_min = crust_thickness(CRUST_NP,ikey)
  enddo
  close(1)

  if(h_moho_min == HUGEVAL .or. h_moho_max == -HUGEVAL) stop 'incorrect moho depths in read_crust_2_0_model'

  end subroutine read_crust_2_0_model

!
!-------------------------------------------------------------------------------------------------
!

  subroutine crust_2_0_CAPsmoothed(lat,lon,velp,vels,rho,thick,abbreviation,code,crust_thickness,crust_vp,crust_vs,crust_rho)

! crustal vp and vs in km/s, layer thickness in km
!
! crust2.0 gets smoothed with a cap of size CAP using NTHETA points
! in the theta direction and NPHI in the phi direction.
! The cap is first rotated to the North Pole for easier implementation.

  use constants
  use model_crust_2_0_par,only: CRUST_NP,CRUST_NLO,CRUST_NLA

  implicit none

  ! sampling rate for CAP points
  integer, parameter :: NTHETA = 4
  integer, parameter :: NPHI = 20

  ! argument variables
  double precision :: lat,lon
  double precision,dimension(CRUST_NP) :: rho,thick,velp,vels
  double precision,dimension(CRUST_NP,CRUST_NLO) :: crust_thickness,crust_vp,crust_vs,crust_rho

  character(len=2) :: code(CRUST_NLO)
  character(len=2) :: abbreviation(CRUST_NLA/2,CRUST_NLA)

  !-------------------------------
  ! work-around to avoid Jacobian problems when stretching mesh elements;
  ! one could also try to slightly change the shape of the doubling element bricks (which cause the problem)...
  !
  ! defines a "critical" region around the andes to have at least a 2-degree smoothing;
  ! critical region can lead to negative Jacobians for mesh stretching when CAP smoothing is too small
  double precision,parameter :: LAT_CRITICAL_ANDES = -20.0d0
  double precision,parameter :: LON_CRITICAL_ANDES = -70.0d0
  double precision,parameter :: CRITICAL_RANGE = 70.0d0
  !-------------------------------

  ! local variables
  double precision :: xlon(NTHETA*NPHI),xlat(NTHETA*NPHI),weight(NTHETA*NPHI)
  double precision :: rhol(CRUST_NP),thickl(CRUST_NP),velpl(CRUST_NP),velsl(CRUST_NP)

  double precision :: weightl,cap_degree
  double precision :: dist
  double precision :: h_sed
  integer :: i,icolat,ilon
  character(len=2) :: crustaltype

  ! small hash table to convert crustal types to key
  integer, dimension(128*128) :: crustalhash_to_key
  integer :: ihash, crustalkey

  ! fill in the hash table
  crustalhash_to_key = -1
  do i=1,CRUST_NLO
    call hash_crustal_type(code(i), ihash)
    if (crustalhash_to_key(ihash) /= -1) stop 'error in crust_2_0_CAPsmoothed: hash table collision'
    crustalhash_to_key(ihash) = i
  enddo

  ! checks latitude/longitude
  if(lat > 90.0d0 .or. lat < -90.0d0 .or. lon > 180.0d0 .or. lon < -180.0d0) then
    print*,'error in lat/lon:',lat,lon
    stop 'error in latitude/longitude range in crust2.0'
  endif

  ! makes sure lat/lon are within crust2.0 range
  if(lat==90.0d0) lat=89.9999d0
  if(lat==-90.0d0) lat=-89.9999d0
  if(lon==180.0d0) lon=179.9999d0
  if(lon==-180.0d0) lon=-179.9999d0

  ! sets up smoothing points based on cap smoothing
  cap_degree = CAP_SMOOTHING_DEGREE_DEFAULT

  ! checks if inside/outside of critical region for mesh stretching
  if( SMOOTH_CRUST_EVEN_MORE ) then
    dist = dsqrt( (lon-LON_CRITICAL_ANDES)**2 + (lat-LAT_CRITICAL_ANDES )**2 )
    if( dist < CRITICAL_RANGE ) then
      ! increases cap smoothing degree
      ! scales between -1 at center and 0 at border
      dist = dist / CRITICAL_RANGE - ONE
      ! shifts value to 1 at center and 0 to the border with exponential decay
      dist = ONE - exp( - dist*dist*10.0d0 )
      ! increases smoothing degree inside of critical region to 2 degree
      cap_degree = cap_degree + dist
    endif
  endif

  ! gets smoothing points and weights
  call CAP_vardegree(lon,lat,xlon,xlat,weight,cap_degree,NTHETA,NPHI)

  ! initializes
  velp(:) = ZERO
  vels(:) = ZERO
  rho(:) = ZERO
  thick(:) = ZERO

  ! loops over weight points
  do i=1,NTHETA*NPHI
    ! gets lat/lon indices
    call icolat_ilon(xlat(i),xlon(i),icolat,ilon)

    crustaltype = abbreviation(icolat,ilon)

    call hash_crustal_type(crustaltype, ihash)
    crustalkey = crustalhash_to_key(ihash)
    if(crustalkey == -1) stop 'error in retrieving crust type key'

    ! gets crust values
    call get_crust_2_0_structure(crustalkey,velpl,velsl,rhol,thickl, &
                            crust_thickness,crust_vp,crust_vs,crust_rho)

    ! sediment thickness
    h_sed = thickl(3) + thickl(4)

    ! takes upper crust value if sediment too thin
    if( h_sed < MINIMUM_SEDIMENT_THICKNESS ) then
      velpl(3) = velpl(5)
      velpl(4) = velpl(5)

      velsl(3) = velsl(5)
      velsl(4) = velsl(5)

      rhol(3) = rhol(5)
      rhol(4) = rhol(5)
    endif

    ! weighting value
    weightl = weight(i)

    ! total, smoothed values
    rho(:) = rho(:) + weightl*rhol(:)
    thick(:) = thick(:) + weightl*thickl(:)
    velp(:) = velp(:) + weightl*velpl(:)
    vels(:) = vels(:) + weightl*velsl(:)
  enddo

  end subroutine crust_2_0_CAPsmoothed

!
!-------------------------------------------------------------------------------------------------
!

  subroutine get_crust_2_0_structure(ikey,vptyp,vstyp,rhtyp,thtp,crust_thickness,crust_vp,crust_vs,crust_rho)

  use model_crust_2_0_par,only: CRUST_NP,CRUST_NLO

  implicit none

  ! argument variables
  integer, intent(in) :: ikey
  double precision, intent(out) :: rhtyp(CRUST_NP),thtp(CRUST_NP)
  double precision, intent(out) :: vptyp(CRUST_NP),vstyp(CRUST_NP)
  double precision :: crust_thickness(CRUST_NP,CRUST_NLO),crust_vp(CRUST_NP,CRUST_NLO)
  double precision :: crust_vs(CRUST_NP,CRUST_NLO),crust_rho(CRUST_NP,CRUST_NLO)

  ! local variables
  integer :: i

  ! set vp,vs and rho for all layers
  do i=1,CRUST_NP
    vptyp(i)=crust_vp(i,ikey)
    vstyp(i)=crust_vs(i,ikey)
    rhtyp(i)=crust_rho(i,ikey)
    thtp(i)=crust_thickness(i,ikey)
  enddo

  ! get distance to Moho from the bottom of the ocean or the ice
  ! value could be used for checking, but is unused so far...
  thtp(CRUST_NP) = thtp(CRUST_NP) - thtp(1) - thtp(2)

  end subroutine get_crust_2_0_structure

