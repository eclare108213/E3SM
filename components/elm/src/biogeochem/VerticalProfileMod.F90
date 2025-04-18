module VerticalProfileMod
  !-----------------------------------------------------------------------
  ! !DESCRIPTION:
  ! Module holding routines for vertical discretization of C and N inputs into deocmposing pools
  !
  ! !USES:
  use shr_kind_mod    , only: r8 => shr_kind_r8
  use shr_log_mod     , only : errMsg => shr_log_errMsg
  use decompMod       , only : bounds_type
  use abortutils      , only : endrun
  use subgridAveMod   , only : p2c
  use SoilStateType   , only : soilstate_type
  use CanopyStateType , only : canopystate_type
  use CNStateType     , only : cnstate_type
  use ColumnType      , only : col_pp                
  use VegetationType       , only : veg_pp                
  !
  implicit none
  save
  private
  !
  ! !PUBLIC MEMBER FUNCTIONS:
  public:: decomp_vertprofiles
  !
  logical , public :: exponential_rooting_profile = .true.
  logical , public :: pftspecific_rootingprofile = .true.
  ! how steep profile is for root C inputs (1/ e-folding depth) (1/m)
  real(r8), public :: rootprof_exp  = 3._r8 
  ! how steep profile is for surface components (1/ e_folding depth) (1/m)
  real(r8), public :: surfprof_exp  = 10._r8      
  !-----------------------------------------------------------------------

contains

  !-----------------------------------------------------------------------
  subroutine decomp_vertprofiles(bounds, &
       num_soilc,filter_soilc,num_soilp,filter_soilp, &
       soilstate_vars, canopystate_vars, cnstate_vars)
    !
    ! !DESCRIPTION:
    !  calculate vertical profiles for distributing soil and litter C and N
    !
    !  Note (WJS, 6-12-13): Because of this routine's placement in the driver sequence (it is
    !  called very early in each timestep, before weights are adjusted and filters are
    !  updated), it may be necessary for this routine to compute values over inactive as well
    !  as active points (since some inactive points may soon become active) - so that's what
    !  is done now. Currently, it seems to be okay to do this, because the variables computed
    !  here seem to only depend on quantities that are valid over inactive as well as active
    !  points. However, note that this routine is (mistakenly) called from two places
    !  currently - the above note applies to its call from the driver, but its call from
    !  SoilLittDecompMod uses the standard filters that just apply over active points
    ! 
    ! !USES:
    use elm_varcon  , only : zsoi, dzsoi, zisoi, dzsoi_decomp
    use elm_varpar  , only : nlevdecomp, nlevgrnd, nlevdecomp_full, maxpatch_pft
    use elm_varctl  , only : use_vertsoilc, iulog, use_dynroot
    use pftvarcon   , only : rootprof_beta, noveg
    !
    ! !ARGUMENTS:
    type(bounds_type)      , intent(in)    :: bounds  
    integer                , intent(in)    :: num_soilc       ! number of soil columns in filter
    integer                , intent(in)    :: filter_soilc(:) ! filter for soil columns
    integer                , intent(in)    :: num_soilp       ! number of soil patches in filter
    integer                , intent(in)    :: filter_soilp(:) ! filter for soil patches
    type(soilstate_type)   , intent(in)    :: soilstate_vars
    type(canopystate_type) , intent(in)    :: canopystate_vars
    type(cnstate_type)     , intent(inout) :: cnstate_vars
    !
    ! !LOCAL VARIABLES:
    real(r8) :: surface_prof(1:nlevdecomp)
    real(r8) :: surface_prof_tot
    real(r8) :: rootfr_tot
    real(r8) :: cinput_rootfr(bounds%begp:bounds%endp, 1:nlevdecomp_full)      ! pft-native root fraction used for calculating inputs
    real(r8) :: col_cinput_rootfr(bounds%begc:bounds%endc, 1:nlevdecomp_full)  ! col-native root fraction used for calculating inputs
    integer  :: c, j, fc, p, fp, pi
    integer  :: alt_ind
    integer  :: nlevbed
    ! debugging temp variables
    real(r8) :: froot_prof_sum
    real(r8) :: croot_prof_sum
    real(r8) :: leaf_prof_sum
    real(r8) :: stem_prof_sum
    real(r8) :: ndep_prof_sum
    real(r8) :: nfixation_prof_sum
    real(r8) :: pdep_prof_sum
    real(r8) :: delta = 1.e-10_r8
    real(r8), parameter :: smallparameter = tiny(1._r8)
    character(len=32) :: subname = 'decomp_vertprofiles'
    !-----------------------------------------------------------------------

    associate(                                                               & 
         nlev2bed             => col_pp%nlevbed                            , & ! Input: [integer (:)     ]  number of layers to bedrock
         rootfr               => soilstate_vars%rootfr_patch               , & ! Input:  [real(r8)  (:,:) ]  fraction of roots in each soil layer  (nlevgrnd)
         
         altmax_lastyear_indx => canopystate_vars%altmax_lastyear_indx_col , & ! Input:  [integer   (:)   ]  frost table depth (m)                              
         
         nfixation_prof       => cnstate_vars%nfixation_prof_col           , & ! Input:  [real(r8)  (:,:) ]  (1/m) profile for N fixation additions          
         ndep_prof            => cnstate_vars%ndep_prof_col                , & ! Input:  [real(r8)  (:,:) ]  (1/m) profile for N fixation additions
         pdep_prof            => cnstate_vars%pdep_prof_col                , & ! Input:  [real(r8)  (:,:) ]  (1/m) profile for P depostition additions          
         
         leaf_prof            => cnstate_vars%leaf_prof_patch              , & ! Output:  [real(r8) (:,:) ]  (1/m) profile of leaves                         
         froot_prof           => cnstate_vars%froot_prof_patch             , & ! Output:  [real(r8) (:,:) ]  (1/m) profile of fine roots                     
         croot_prof           => cnstate_vars%croot_prof_patch             , & ! Output:  [real(r8) (:,:) ]  (1/m) profile of coarse roots                   
         stem_prof            => cnstate_vars%stem_prof_patch              , & ! Output:  [real(r8) (:,:) ]  (1/m) profile of stems                          
         
         begp                 => bounds%begp                               , &
         endp                 => bounds%endp                               , &
         begc                 => bounds%begc                               , &
         endc                 => bounds%endc                                 &
         )

      if (use_vertsoilc) then

         ! define a single shallow surface profile for surface additions (leaves, stems, and N deposition)
         surface_prof(:) = 0._r8
         do j = 1, nlevdecomp
            surface_prof(j) = exp(-surfprof_exp * zsoi(j)) / dzsoi_decomp(j)
         end do

         ! initialize profiles to zero
         leaf_prof(begp:endp, :)      = 0._r8
         froot_prof(begp:endp, :)     = 0._r8
         croot_prof(begp:endp, :)     = 0._r8
         stem_prof(begp:endp, :)      = 0._r8
         nfixation_prof(begc:endc, :) = 0._r8
         ndep_prof(begc:endc, :)      = 0._r8
         pdep_prof(begc:endc, :)      = 0._r8

         cinput_rootfr(begp:endp, :)     = 0._r8
         col_cinput_rootfr(begc:endc, :) = 0._r8

         if ( exponential_rooting_profile ) then
            if ( .not. pftspecific_rootingprofile ) then
               ! define rooting profile from exponential parameters
               do j = 1, nlevdecomp
                  do fp = 1,num_soilp
                     p = filter_soilp(fp)
                     cinput_rootfr(p,j) = exp(-rootprof_exp * zsoi(j)) / dzsoi_decomp(j)
                  end do
               end do
            else
               ! use beta distribution parameter from Jackson et al., 1996
               do fp = 1,num_soilp
                  p = filter_soilp(fp)
                  c = veg_pp%column(p)
                  nlevbed = nlev2bed(c)
                  rootfr_tot = 0._r8
                  if (veg_pp%itype(p) /= noveg) then
                     do j = 1, nlevdecomp
                        if (j <= nlevbed) then
                           cinput_rootfr(p,j) = ( rootprof_beta(veg_pp%itype(p)) ** (zisoi(j-1)*100._r8) - &
                             rootprof_beta(veg_pp%itype(p)) ** (zisoi(j)*100._r8) ) &
                             / dzsoi_decomp(j)
                           rootfr_tot = rootfr_tot + cinput_rootfr(p,j) * dzsoi_decomp(j)
                        else
                           cinput_rootfr(p,j) = 0._r8
                        end if
                     end do
                     if (nlevbed < nlevdecomp) then
                        do j = 1, nlevbed
                           cinput_rootfr(p,j) = cinput_rootfr(p,j) / rootfr_tot
                        end do
                     end if
                  else
                     cinput_rootfr(p,1) = 1._r8 / dzsoi_decomp(1)
                  endif
               end do
            endif
         else
            do j = 1, nlevdecomp
               ! use standard CLM root fraction profiles
               do fp = 1,num_soilp
                  p = filter_soilp(fp)
                  cinput_rootfr(p,j) = rootfr(p,j) / dzsoi_decomp(j)
               end do
            end do
         endif

         do fp = 1,num_soilp
            p = filter_soilp(fp)
            c = veg_pp%column(p)
            nlevbed = nlev2bed(c)
            ! integrate rootfr over active layer of soil column
            rootfr_tot = 0._r8
            surface_prof_tot = 0._r8
            do j = 1, min(max(altmax_lastyear_indx(c), 1), nlevdecomp)
               rootfr_tot = rootfr_tot + cinput_rootfr(p,j) * dzsoi_decomp(j)
               if (nlevbed < nlevdecomp) then
                  surface_prof_tot = surface_prof_tot + exp(log(surface_prof(j)) * zisoi(nlevdecomp) / &
                  	zisoi(nlevbed)) * dzsoi_decomp(j)
               else
                  surface_prof_tot = surface_prof_tot + surface_prof(j) * dzsoi_decomp(j)
               end if
            end do
            if ( (altmax_lastyear_indx(c) > 0) .and. (rootfr_tot > smallparameter) .and. (surface_prof_tot > smallparameter) ) then
               ! where there is not permafrost extending to the surface, integrate the profiles over the active layer
               ! this is equivalnet to integrating over all soil layers outside of permafrost regions
               do j = 1, min(max(altmax_lastyear_indx(c), 1), nlevdecomp)
                  froot_prof(p,j) = cinput_rootfr(p,j) / rootfr_tot
                  croot_prof(p,j) = cinput_rootfr(p,j) / rootfr_tot
                  ! set all surface processes to shallower profile
                  if (j <= nlevbed) then
                     if (nlevbed < nlevdecomp) then
                        leaf_prof(p,j) = exp(log(surface_prof(j)) * zisoi(nlevdecomp) / zisoi(nlevbed))/ &
                        	surface_prof_tot
                        stem_prof(p,j) = exp(log(surface_prof(j)) * zisoi(nlevdecomp) / zisoi(nlevbed))/ &
                        	surface_prof_tot
                     else
                        leaf_prof(p,j) = surface_prof(j)/ surface_prof_tot
                        stem_prof(p,j) = surface_prof(j)/ surface_prof_tot
                     end if
                  end if
               end do
            else
               ! if fully frozen, or no roots, put everything in the top layer
               froot_prof(p,1) = 1._r8/dzsoi_decomp(1)
               croot_prof(p,1) = 1._r8/dzsoi_decomp(1)
               leaf_prof(p,1) = 1._r8/dzsoi_decomp(1)
               stem_prof(p,1) = 1._r8/dzsoi_decomp(1)
            endif

         end do

         !! aggregate root profile to column
         ! call p2c (decomp, nlevdecomp_full, &
         !      cinput_rootfr(bounds%begp:bounds%endp, :), &
         !      col_cinput_rootfr(bounds%begc:bounds%endc, :), &
         !      'unity')
         do pi = 1,maxpatch_pft
            do fc = 1,num_soilc
               c = filter_soilc(fc)
               if (pi <=  col_pp%npfts(c)) then
                  p = col_pp%pfti(c) + pi - 1
                  do j = 1,nlevdecomp
                     col_cinput_rootfr(c,j) = col_cinput_rootfr(c,j) + cinput_rootfr(p,j) * veg_pp%wtcol(p)
                  end do
               end if
            end do
         end do

         ! repeat for column-native profiles: Ndep and Nfix
         do fc = 1,num_soilc
            c = filter_soilc(fc)
            nlevbed = nlev2bed(c)
            rootfr_tot = 0._r8
            surface_prof_tot = 0._r8
            ! redo column ntegration over active layer for column-native profiles
            alt_ind = min(max(altmax_lastyear_indx(c), 1), nlevdecomp)
            do j = 1, min(alt_ind, nlevbed)
               rootfr_tot = rootfr_tot + col_cinput_rootfr(c,j) * dzsoi_decomp(j)
               surface_prof_tot = surface_prof_tot + surface_prof(j) * dzsoi_decomp(j)
            end do
            if(col_pp%is_fates(c))then
               if ( (altmax_lastyear_indx(c) > 0) .and. (surface_prof_tot > smallparameter) ) then
                  do j = 1,min(alt_ind, nlevbed)
                     nfixation_prof(c,j) = surface_prof(j)/ surface_prof_tot
                     ndep_prof(c,j) = surface_prof(j)/ surface_prof_tot
                     pdep_prof(c,j) = surface_prof(j)/ surface_prof_tot
                  end do
               else
                  nfixation_prof(c,1) = 1._r8/dzsoi_decomp(1)
                  ndep_prof(c,1) = 1._r8/dzsoi_decomp(1)
                  pdep_prof(c,1) = 1._r8/dzsoi_decomp(1)
               endif
            else
               if ( (altmax_lastyear_indx(c) > 0) .and. (rootfr_tot > smallparameter) .and. (surface_prof_tot > smallparameter) ) then
                  do j = 1,  min(max(altmax_lastyear_indx(c), 1), nlevdecomp)
                     nfixation_prof(c,j) = col_cinput_rootfr(c,j) / rootfr_tot
                     if (j <= nlevbed) then
                        ndep_prof(c,j) = surface_prof(j)/ surface_prof_tot
                        pdep_prof(c,j) = surface_prof(j)/ surface_prof_tot
                     end if
                  end do
               else
                  nfixation_prof(c,1) = 1._r8/dzsoi_decomp(1)
                  ndep_prof(c,1) = 1._r8/dzsoi_decomp(1)
                  pdep_prof(c,1) = 1._r8/dzsoi_decomp(1) 
               endif
            end if
         end do

      else

         ! for one layer decomposition model, set profiles to unity
         leaf_prof(begp:endp, :) = 1._r8
         froot_prof(begp:endp, :) = 1._r8
         croot_prof(begp:endp, :) = 1._r8
         stem_prof(begp:endp, :) = 1._r8
         nfixation_prof(begc:endc, :) = 1._r8
         ndep_prof(begc:endc, :) = 1._r8
         pdep_prof(begc:endc, :) = 1._r8

      end if

      ! check to make sure integral of all profiles = 1.
      do fc = 1,num_soilc
         c = filter_soilc(fc)
         ndep_prof_sum = 0._r8
         nfixation_prof_sum = 0._r8
         pdep_prof_sum = 0._r8
         do j = 1, nlevdecomp
            ndep_prof_sum = ndep_prof_sum + ndep_prof(c,j) *  dzsoi_decomp(j)
            nfixation_prof_sum = nfixation_prof_sum + nfixation_prof(c,j) *  dzsoi_decomp(j)
            pdep_prof_sum = pdep_prof_sum + pdep_prof(c,j) *  dzsoi_decomp(j)
         end do
         if ( ( abs(ndep_prof_sum - 1._r8) > delta ) .or.  ( abs(nfixation_prof_sum - 1._r8) > delta ) .or. &
              ( abs(pdep_prof_sum - 1._r8) > delta )  ) then
            write(iulog, *) 'profile sums: ', ndep_prof_sum, nfixation_prof_sum, pdep_prof_sum
            write(iulog, *) 'c: ', c
            write(iulog, *) 'altmax_lastyear_indx: ', altmax_lastyear_indx(c)
            write(iulog, *) 'nfixation_prof: ', nfixation_prof(c,:)
            write(iulog, *) 'ndep_prof: ', ndep_prof(c,:)
            write(iulog, *) 'pdep_prof: ', pdep_prof(c,:)
            write(iulog, *) 'cinput_rootfr: ', col_cinput_rootfr(c,:)
            write(iulog, *) 'dzsoi_decomp: ', dzsoi_decomp(:)
            write(iulog, *) 'surface_prof: ', surface_prof(:)
            write(iulog, *) 'npfts(c): ', col_pp%npfts(c)
            do p = col_pp%pfti(c), col_pp%pfti(c) + col_pp%npfts(c) -1
               write(iulog, *) 'p, itype(p), wtcol(p): ', p, veg_pp%itype(p), veg_pp%wtcol(p)
               write(iulog, *) 'cinput_rootfr(p,:): ', cinput_rootfr(p,:)
            end do
            call endrun(msg=" ERROR: _prof_sum-1>delta"//errMsg(__FILE__, __LINE__))
         endif
      end do

      do fp = 1,num_soilp
         p = filter_soilp(fp)
         froot_prof_sum = 0._r8
         croot_prof_sum = 0._r8
         leaf_prof_sum = 0._r8
         stem_prof_sum = 0._r8
         do j = 1, nlevdecomp
            froot_prof_sum = froot_prof_sum + froot_prof(p,j) *  dzsoi_decomp(j)
            croot_prof_sum = croot_prof_sum + croot_prof(p,j) *  dzsoi_decomp(j)
            leaf_prof_sum = leaf_prof_sum + leaf_prof(p,j) *  dzsoi_decomp(j)
            stem_prof_sum = stem_prof_sum + stem_prof(p,j) *  dzsoi_decomp(j)
         end do
         if ( ( abs(froot_prof_sum - 1._r8) > delta ) .or.  ( abs(croot_prof_sum - 1._r8) > delta ) .or. &
              ( abs(stem_prof_sum - 1._r8) > delta ) .or.  ( abs(leaf_prof_sum - 1._r8) > delta ) ) then
            c = veg_pp%column(p)
            write(iulog, *) 'profile sums: ', froot_prof_sum, croot_prof_sum, leaf_prof_sum, stem_prof_sum
            write(iulog, *) 'c: ',c
            write(iulog, *) 'altmax_lastyear_indx: ', altmax_lastyear_indx(c)
            write(iulog, *) 'cinput_rootfr: ', col_cinput_rootfr(c,:)
            write(iulog, *) 'dzsoi_decomp: ', dzsoi_decomp(:)
            write(iulog, *) 'surface_prof: ', surface_prof(:)
            write(iulog, *) 'p, itype(p), wtcol(p): ', p, veg_pp%itype(p), veg_pp%wtcol(p)
            write(iulog, *) 'cinput_rootfr(p,:): ', cinput_rootfr(p,:)
            write(iulog,*)  'croot_prof(p,:): ',croot_prof(p,:)
            write(iulog,*)  'froot_prof(p,:): ',froot_prof(p,:)
            write(iulog,*)  'leaf_prof(p,:): ',leaf_prof(p,:)
            write(iulog,*)  'stem_prof(p,:): ',stem_prof(p,:)
            call endrun(msg=' ERROR: sum-1 > delta'//errMsg(__FILE__, __LINE__))
         endif
      end do

    end associate 

  end subroutine decomp_vertprofiles
  
end module VerticalProfileMod
