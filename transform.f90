module transform

  use hungarian

  implicit none

  public :: &
       trans, &
       center, &
       fastoptimization

  private :: &
       eye, &
       init_random_seed, &
       norm, &
       det, &
       free_trans, &
       cost_map, &
       analytical_gd_rot, &
       gradient_descent_explore

contains

  subroutine init_random_seed()
    ! Copied form the GCC docs: https://gcc.gnu.org/onlinedocs/gcc-4.6.4/gfortran/RANDOM_005fSEED.html#RANDOM_005fSEED
    INTEGER :: i, n, clock
    INTEGER, DIMENSION(:), ALLOCATABLE :: seed

    CALL RANDOM_SEED(size = n)
    ALLOCATE(seed(n))

    CALL SYSTEM_CLOCK(COUNT=clock)

    seed = clock + 37 * (/ (i - 1, i = 1, n) /)
    CALL RANDOM_SEED(PUT = seed)

    DEALLOCATE(seed)

  end subroutine init_random_seed

  subroutine trans(pos,n,theta,u,vec)

    integer, intent(in) :: &
         n ! Number of atoms

    double precision, intent(inout), dimension(3,n) :: &
         pos  ! position matrix

    double precision, intent(in), dimension(3,1) :: &
         u, &    ! Rotation axis (unitary vector)
         vec     ! Translation vector

    double precision, dimension(3) :: &
         tvec    ! displacement from origin

    double precision, intent(in) :: &
         theta    ! angle of rotation

    tvec = vec(:,1) + sum(pos,2) / size(pos,2)

    call center(pos,n)

    pos = free_trans(pos, rot_mat(theta, u), tvec)

  end subroutine trans

  function rot_mat(theta,u) result(R)

    double precision, intent(in), dimension(3,1) :: &
         u     ! Rotation axis (unitary vector)

    double precision, intent(in) :: &
         theta    ! angle of rotation

    double precision, dimension(3,3) :: &
         Q, & ! cross product matrix
         P    ! u.u**T

    double precision, dimension(3,3) :: &
         R    ! Transformation matrix

    P = matmul(u,transpose(u))
    Q = transpose(reshape((/0.0d0,-u(3,1),u(2,1),u(3,1),0.0d0,-u(1,1),-u(2,1),u(1,1),0.0d0/),(/3,3/)))

    R = P + (eye() - P)*cos(theta) + Q*sin(theta)

  end function rot_mat


  subroutine center(pos,n)

    integer, intent(in) :: &
         n ! Number of atoms

    double precision, intent(inout), dimension(3,n) :: &
         pos  ! position matrix

    pos = pos - spread(sum(pos,2) / size(pos,2),2,size(pos,2))

  end subroutine center

  function free_trans(pos, mat, vec)

    double precision, intent(in), dimension(:,:) :: &
         pos  ! position matrix

    double precision, intent(in), dimension(3,3) :: &
         mat

    double precision, intent(in), dimension(3) :: &
         vec

    double precision, dimension(size(pos,1), size(pos,2)) :: &
         free_trans

    free_trans = matmul(mat, pos) + spread(vec, 2, size(pos,2))

  end function free_trans

  function cost_map(Apos,Bpos, n_in) result(cost)

    double precision, intent(in), dimension(:,:) :: &
         Apos, Bpos  ! Rotation axis
    integer, optional, intent(in) :: &
         n_in
    double precision, dimension(size(Apos,2),size(Apos,2)) :: &
         cost
    integer :: &
         i,j,n ! Iterators

    cost = 0

    n = size(Apos,2)

    if (present(n_in)) n = n_in

    do i=1,size(Apos,2)
       do j=1,size(Bpos,2)
          if (j <= n) then
             cost(i,j) = norm(Apos(:,i)-Bpos(:,j))
          elseif (i <= int(n/2)) then !TMP 
             cost(i,j) = 1000
          endif
       enddo
    enddo

  end function cost_map

  subroutine mapping(Apos_mapped, Bpos_opt, Apos, Bpos, tBpos, frac, atoms, n_atoms)
    
    integer, intent(in) :: &
         n_atoms ! Number of types of atoms
    double precision, intent(in), dimension(:,:) :: &
         Apos, Bpos, tBpos  ! position matrix
    integer, intent(in), dimension(n_atoms) :: &
         atoms
    double precision, intent(in) :: &
         frac
    double precision, intent(out), &
         dimension(3,int(frac*size(Apos,2)/sum(atoms))*sum(atoms)) :: &
         Apos_mapped, Bpos_opt  ! position matrix
    double precision, allocatable, dimension(:,:) :: &
         dmat
    integer, allocatable, dimension(:) :: &
         map
    double precision :: &
         dist_map
    integer :: &
         An_cell, & ! Number of cells
         i,l, &
         id, idx, &
         n, n_frac

    An_cell = size(Apos,2)/sum(atoms)

    id = 0
    idx = 0
    n = 0

    do i=0,n_atoms-1

       id = id + n

       n = An_cell*atoms(i+1)
       n_frac = int(An_cell*frac)*atoms(i+1)

       allocate(dmat(n,n), map(n))

       dmat = cost_map(Apos( : , id + 1 : id + n ), &
            tBpos( : , id + 1 : id + n ),n_frac)

       call munkres(dist_map, map, dmat, n)
       
       map = map + id

       do l=1, int(n*frac)
          idx = idx + 1 
          Apos_mapped(:,idx) = Apos(:,map(l))
          Bpos_opt(:,idx) = Bpos(:,id+l)
       enddo

       deallocate(dmat,map)

    enddo

  end subroutine mapping

  function eye() result(a)
    !Copied from Rosetta Code at: https://rosettacode.org/wiki/Identity_matrix#Fortran
    ! Checked and modified for double
    double precision :: a(3,3)
    integer :: i,j

    forall(i = 1:3, j = 1:3) a(i,j) = (i/j)*(j/i)

  end function eye

  function norm(a)

    double precision :: norm
    double precision, dimension(3), intent(in) :: a

    norm = sqrt(sum(a**2))

  end function norm

  recursive function det(a,n) result(accumulation)
    ! Copied from Rosetta Code at: https://rosettacode.org/wiki/Matrix_arithmetic#Fortran
    ! Checked and modified for determinant only, and double precision
    double precision, dimension(n,n), intent(in) :: a
    integer, intent(in) :: n
    double precision, dimension(n-1, n-1) :: b
    double precision :: accumulation
    integer :: i, sgn
    if (n == 1) then
       accumulation = a(1,1)
    else
       accumulation = 0
       sgn = 1
       do i=1, n
          b(:, :(i-1)) = a(2:, :i-1)
          b(:, i:) = a(2:, i+1:)
          accumulation = accumulation + sgn * a(1, i) * det(b, n-1)
          sgn = -sgn
       enddo
    endif
  end function det
  
  subroutine analytical_gd_rot(theta, u, vec, Apos, Bpos, n_iter, rate1, rate2)

    integer, intent(in) :: &
         n_iter ! Number of atoms

    double precision, intent(in) :: &
         rate1, & ! Rate for angles
         rate2    ! Rate for disp

    double precision, intent(in), dimension(:,:) :: &
         Apos, &
         Bpos ! Bpos ordered according to the mapping

    double precision, dimension(3,size(Bpos,2)) :: &
         E ! position matrix

    double precision, intent(inout), dimension(3,1) :: &         
         vec, &     ! Translation vector
         u

    double precision, intent(inout) :: &
         theta    ! Transformation matrix

    double precision, dimension(3,3) :: &
         Px, Py, Pt, & ! Temporary transformation matrix
         Qx, Qy, Qt, &
         Mx, My, Mt, M

    double precision, dimension(size(Bpos,2),1) :: &
         ones

    double precision :: &
         dist, &
         dist_prev

    integer :: &
         i,j ! Iterator

    double precision, parameter :: &
         tol = 1d-10

    ones = 1.0d0

    dist = 0
    dist_prev = tol+1

    j=0
    do while (j < n_iter .and. abs(dist - dist_prev) > tol)
       j=j+1

       M = rot_mat(theta,u)

       dist_prev = dist
       dist = sum(sqrt(sum((Apos - free_trans(Bpos,M,vec))**2,1)))

       E = Apos - free_trans(Bpos,M,vec)
       E = E / spread(sqrt(sum(E**2,1)),1,3)

       ! ! ux and uy is for 3D only
       ! Px = transpose(reshape((/2*u(1,1), &
       !      u(2,1) , &
       !      (u(1,1)*(1-u(2,1)**2) - 2*u(1,1)**3)/sqrt(u(1,1)**2*(1-u(2,1)**2)-u(1,1)**4), &
       !      u(2,1)  , &
       !      u(2,1)**2, &
       !      -u(1,1)*u(2,1)**2/sqrt(u(2,1)**2*(1-u(1,1)**2)-u(2,1)**4), &
       !      (u(1,1)*(1-u(2,1)**2) - 2*u(1,1)**3)/sqrt(u(1,1)**2*(1-u(2,1)**2)-u(1,1)**4) , &
       !      -u(1,1)*u(2,1)**2/sqrt(u(2,1)**2*(1-u(1,1)**2)-u(2,1)**4), &
       !      -2*u(1,1)/), &
       !      (/3,3/)))
       ! Qx = transpose(reshape((/0.0d0, &
       !      u(1,1)/sqrt(1-u(1,1)**2-u(2,1)**2), &
       !      u(2,1), &
       !      -u(1,1)/sqrt(1-u(1,1)**2-u(2,1)**2), &
       !      0.0d0, &
       !      -1.0d0, &
       !      -u(2,1), &
       !      1.0d0, &
       !      0.0d0/), &
       !      (/3,3/)))

       ! Mx = Px + (eye() - Px)*cos(theta) + Qx*sin(theta)

       ! Py = transpose(reshape((/u(1,1)**2, &
       !      u(1,1) , &
       !      -u(2,1)*u(1,1)**2/sqrt(u(1,1)**2*(1-u(2,1)**2)-u(1,1)**4), &
       !      u(1,1)  , &
       !      2*u(2,1), &
       !      (u(2,1)*(1-u(1,1)**2) - 2*u(2,1)**3)/sqrt(u(2,1)**2*(1-u(1,1)**2)-u(2,1)**4), &
       !      -u(2,1)*u(1,1)**2/sqrt(u(1,1)**2*(1-u(2,1)**2)-u(1,1)**4) , &
       !      (u(2,1)*(1-u(1,1)**2) - 2*u(2,1)**3)/sqrt(u(2,1)**2*(1-u(1,1)**2)-u(2,1)**4), &
       !      -2*u(2,1)/), &
       !      (/3,3/)))
       ! Qy = transpose(reshape((/0.0d0, &
       !      u(2,1)/sqrt(1-u(1,1)**2-u(2,1)**2), &
       !      1.0d0, &
       !      -u(2,1)/sqrt(1-u(1,1)**2-u(2,1)**2), &
       !      0.0d0, &
       !      u(1,1), &
       !      -1.0d0, &
       !      u(1,1), &
       !      0.0d0/), &
       !      (/3,3/)))

       ! My = Py + (eye() - Py)*cos(theta) + Qy*sin(theta)

       Pt = matmul(u,transpose(u))
       Qt = transpose(reshape((/0.0d0,-u(3,1),u(2,1),u(3,1),0.0d0,-u(1,1),-u(2,1),u(1,1),0.0d0/),(/3,3/)))

       Mt = Pt - (eye() - Pt)*sin(theta) + Qt*cos(theta)

       ! u(1,1) = u(1,1) + rate1*dist*sum(matmul(E,transpose(Bpos)) * Mx)
       ! u(2,1) = u(2,1) + rate1*dist*sum(matmul(E,transpose(Bpos)) * My)
       ! u(3,1) = sqrt(1-u(1,1)**2-u(2,1)**2)
       theta = theta + rate1*dist*sum(matmul(E,transpose(Bpos)) * Mt)
       vec = vec + rate2*dist*matmul(E,ones)

    enddo

  end subroutine analytical_gd_rot

  subroutine analytical_gd_free(tmat, vec, Apos, Bpos, n_iter, rate1, rate2)

    integer, intent(in) :: &
         n_iter ! Number of atoms

    double precision, intent(in) :: &
         rate1, & ! Rate for angles
         rate2    ! Rate for disp

    double precision, intent(in), dimension(:,:) :: &
         Apos, &
         Bpos ! Bpos ordered according to the mapping

    double precision, dimension(3,size(Bpos,2)) :: &
         E ! position matrix

    double precision, intent(inout), dimension(3,3) :: &         
         tmat     ! Translation vector

    double precision, intent(inout), dimension(3,1) :: &         
         vec     ! Translation vector

    double precision, dimension(size(Bpos,2),1) :: &
         ones

    double precision :: &
         dist, &
         dist_prev

    integer :: &
         j ! Iterator

    double precision, parameter :: &
         tol = 1d-8

    ones = 1.0d0

    dist = 0
    dist_prev = tol+1

    j=0
    do while (j < n_iter .and. abs(dist - dist_prev) > tol)
       j=j+1

       dist_prev = dist
       dist = sum(sqrt(sum((Apos - free_trans(Bpos,tmat,vec))**2,1)))

       
       E = Apos - free_trans(Bpos,tmat,vec)
       E = E / spread(sqrt(sum(E**2,1)),1,3)

       tmat = tmat + rate1*dist*matmul(E,transpose(Bpos))
       vec = vec + rate2*dist*matmul(E,ones)

    enddo

  end subroutine analytical_gd_free
  
  subroutine gradient_descent_explore(theta,u, vec, Apos, Bpos, cell, icell, &
       frac, atoms, n_atoms, n_iter, n_ana, n_conv, rate1, rate2)
    ! New Gradient Descent Random

    use omp_lib

    integer, intent(in) :: &
         n_iter, n_atoms, & ! Number of atoms
         n_ana, &
         n_conv

    double precision, intent(in) :: &
         rate1, & ! Rate for angles
         rate2, & ! Rate for disp
         frac ! Fraction of A and B to use in optimisation

    double precision :: &
         rand_rate1, & ! Rate for angles
         rand_rate2 ! Rate for disp

    integer, intent(in), dimension(n_atoms) :: &
         atoms

    double precision, intent(in), dimension(:,:) :: &
         Apos, Bpos ! Centered position of the atoms

    double precision, intent(in), dimension(3,3) :: &
         cell, &  ! cell
         icell ! inverse of cell
    
    double precision, dimension(3,size(Bpos,2)) :: &
         postmp, & ! position matrix
         tBpos

    double precision, dimension(3,int(frac*size(Apos,2)/sum(atoms))*sum(atoms)) :: &
         Apos_mapped, & ! position matrix
         Bpos_opt
    
    double precision, intent(out), dimension(3) :: &
         vec, &     ! Translation vector
         u

    double precision, dimension(3) :: &
         vec_local, &     ! Translation vector
         u_local
    
    double precision, intent(out) :: &
         theta

    double precision, dimension(3,3) :: &
         mat    ! Transformation matrix

    double precision, dimension(3,3) :: &
         mat_tmp, & ! Temporary transformation matrix
         mat_out, & ! Output transformation matrix
         mat_min, &
         P,Q

    double precision, allocatable, dimension(:,:) :: &
         dmat

    integer, allocatable, dimension(:) :: &
         map

    double precision :: &
         dist_plus, & ! distance when adding dx
         dist_minus, & ! distance when substracting dx
         accept, & ! Accept step
         dist_cur, &
         dist_map, &
         dist_stretch, &
         mul_vec, &
         diag, &
         theta_local

    double precision, allocatable, dimension(:) :: &
         dist_min, &
         theta_min

    double precision, allocatable, dimension(:,:) :: &
         u_min, &
         vec_min
    
    integer :: &
         i,j,k,l, & ! Iterator
         id, idx, &
         n, & ! Size of Bpos
         An_cell, Bn_cell, &
         n_threads, thread, &
         pos

    double precision, parameter :: &
         pi = 3.141592653589793d0

    diag = 0
    diag = max(norm(cell(:,1) + cell(:,2) + cell(:,3)),diag)
    diag = max(norm(-cell(:,1) + cell(:,2) + cell(:,3)),diag)
    diag = max(norm(cell(:,1) - cell(:,2) + cell(:,3)),diag)
    diag = max(norm(-cell(:,1) - cell(:,2) + cell(:,3)),diag)

    mul_vec = diag*2/sqrt(2.0d0) !Only in 2D sqrt(3) in 3D
    
    !$omp parallel default(private) shared(dist_min, &
    !$omp theta_min, u_min, vec_min, u, theta, vec) &
    !$omp firstprivate(n_iter, mul_vec, cell, frac, &
    !$omp icell, n_conv, n_ana, Apos, Bpos, rate1, rate2, atoms, n_atoms)

    call init_random_seed()
    
    n_threads = OMP_get_num_threads()

    !$omp single
    allocate(dist_min(n_threads), &
         theta_min(n_threads), &
         u_min(3,n_threads),&
         vec_min(3,n_threads))
    !$omp end single

    thread = OMP_get_thread_num() + 1
    
    dist_min(thread) = sum(sqrt(sum((Apos - Bpos)**2,1)))
    
    !$omp do
    do j=1, n_iter
       
       call random_number(theta_local)
       call random_number(u_local)
       call random_number(vec_local)

       theta_local = theta_local*2*pi

       vec_local = vec_local - (/0.5d0,0.5d0,0.5d0/)
       vec_local(3) = 0.0d0 ! 2D only

       vec_local = vec_local*mul_vec
       
       vec_local = vec_local - matmul(cell,nint(matmul(icell,vec_local))) 

       ! ! 3D only
       ! u_local = u_local - (/0.5d0,0.5d0,0.5d0/)
       ! u_local = u_local / norm(u_local)
       ! u_local(3) = abs(u_local(3))

       u_local =  (/0.0d0,0.0d0,1.0d0/) ! 2D only

       write(*,*) "New initial step", thread, j
       
       do k=1, n_conv

          tBpos = free_trans(Bpos,rot_mat(theta_local,u_local),vec_local)

          call mapping(Apos_mapped, Bpos_opt, Apos, Bpos, tBpos, &
               frac, atoms, n_atoms)

          call analytical_gd_rot(theta_local, u_local, vec_local, Apos_mapped, Bpos_opt, &
               n_ana, rate1, rate2)

       enddo

       dist_cur = sum(sqrt(sum((Apos_mapped - free_trans(Bpos_opt,rot_mat(theta_local,u_local),vec_local))**2,1)))

       if (dist_cur < dist_min(thread)) then
          dist_min(thread) = dist_cur
          theta_min(thread) = theta_local
          u_min(:,thread) = u_local
          vec_min(:,thread) = vec_local
       endif

    enddo
    !$omp end do

    !$omp single
    pos = minloc(dist_min, 1)
    u = u_min(:,pos)
    theta = theta_min(pos)
    vec = vec_min(:,pos)

    deallocate(dist_min, &
         theta_min, &
         u_min,&
         vec_min)
    !$omp end single 
    
    !$omp end parallel

  end subroutine gradient_descent_explore

  subroutine fastoptimization(Apos_out, Bpos_out, Bpos_out_stretch, &
       n_out, tmat, dmin, &
       Apos, na, Bpos, nb, &
       frac, Acell, iAcell, atoms, n_atoms, &
       n_iter, n_ana, n_conv, n_adjust, &
       rate1, rate2)

    integer, intent(in) :: &
         na, nb, & ! Total number of atoms
         n_atoms ! Number of types of atoms per cell

    double precision, intent(in) :: &
         rate1, &  ! Rate of the gradient descent for angles
         rate2     ! Rate of the gradient descent for displacement

    integer, intent(in) :: &
         n_iter, &   ! Number of iteration of the gradient descent
         n_ana, &
         n_conv, &
         n_adjust

    double precision, intent(inout), dimension(3,na) :: &
         Apos ! Position of the atoms

    double precision, intent(inout), dimension(3,nb) :: &
         Bpos ! Position of the atoms

    double precision, intent(out), dimension(3,na) :: &
         Apos_out ! Position of the atoms

    double precision, intent(out), dimension(3,nb) :: &
         Bpos_out, & ! Position of the atoms
         Bpos_out_stretch

    double precision, dimension(3,nb) :: &
         tBpos ! Position of the atoms

    integer, intent(out) :: &
         n_out

    double precision, intent(in), dimension(3,3) :: &
         Acell, & ! Unit cell of A
         iAcell

    double precision, intent(in) :: &
         frac ! Fraction of A and B to use in optimisation

    double precision, allocatable, dimension(:,:) :: &
         inBpos ! Position of the atoms

    integer, intent(in), dimension(n_atoms) :: &
         atoms !Number of atoms of each type

    double precision, intent(out) :: &
         dmin

    double precision, dimension(3) :: &
         vec, & ! Translation vecto
         u      ! Rotation axis

    double precision :: &
         theta, & ! Rotation angle
         d, &
         dist_map, &
         dist_stretch

    double precision, allocatable, dimension(:,:) :: &
         dmat

    double precision, dimension(na,nb) :: &
         mat

    double precision, intent(out), dimension(3,3) :: &
         tmat ! Transformation matrix

    double precision, &
         dimension(3,int(frac*size(Apos,2)/sum(atoms))*sum(atoms)) :: &
         Apos_mapped, Bpos_opt, &
         tBpos_opt, &
         Bpos_opt_stretch ! position matrix

    integer :: &
         i, j, &
         n, id, &
         An_cell, Bn_cell

    double precision, parameter :: &
         pi = 3.141592653589793d0

    n_out = int(frac*size(Apos,2)/sum(atoms))*sum(atoms)
    Apos_out = 0
    Bpos_out = 0

    ! Center both cells at the geometric center
    call center(Bpos,nb)
    call center(Apos,na)

    call gradient_descent_explore(theta, u, vec, Apos, Bpos, Acell, iAcell, &
         frac, atoms,n_atoms,n_iter, n_ana, n_conv, rate1, rate2)
    
    ! u =  (/0.0d0,0.0d0,1.0d0/) ! TMP
    ! theta =  6.2831852718155048d0  ! TMP
    ! vec =  (/0.21045421936607500d0,-9.7911915001716089d-4,0.0d0/) ! TMP
    ! associated distance: 71.791803060241662
    
    tmat = rot_mat(theta,u)
    
    do i=1,n_adjust

       do j=1,n_conv
       
          tBpos = free_trans(Bpos,tmat,vec)

          call mapping(Apos_mapped, Bpos_opt, Apos, Bpos, tBpos, &
               frac, atoms, n_atoms)
          
          theta = 0
          tBpos_opt = free_trans(Bpos_opt,tmat,(/0.0d0,0.0d0,0.0d0/))
          
          call analytical_gd_rot(theta, u, vec, Apos_mapped, tBpos_opt, &
               n_ana*100, rate1, rate2)
          
          tmat = matmul(rot_mat(theta,u),tmat)

          
          theta = 0
          
          call analytical_gd_rot(theta, u, vec, Apos_mapped, Bpos_opt, &
               n_ana*1000, rate1, rate2)

       enddo

       write(*,*) "--------------> Adjustment step:", i

       write(*,*) "Stretched distance:", sum(sqrt(sum((Apos_mapped - free_trans(Bpos_opt, tmat, vec))**2,1)))

       write(*,*) "Unstretched distance:", sum(sqrt(sum((Apos_mapped - free_trans(Bpos_opt, rot_mat(theta,u), vec))**2,1)))

       call analytical_gd_free(tmat, vec, Apos_mapped, Bpos_opt, n_ana*100, rate1, rate2)
       
       
    enddo
    
    ! vec = vec + sum(free_trans(Bpos_opt,rot_mat(theta,u),vec) - Apos_mapped,2) / n_out
    
    Bpos_opt_stretch = free_trans(Bpos_opt,tmat,vec)

    Bpos_opt = free_trans(Bpos_opt,rot_mat(theta,u),vec)
    
    Bpos_out(:,1:n_out) = Bpos_opt
    Bpos_out_stretch(:,1:n_out) = Bpos_opt_stretch
    Apos_out(:,1:n_out) = Apos_mapped

    dmin = sum(sqrt(sum((Apos_mapped - Bpos_opt)**2,1)))

    ! ! Print the cost matrix
    ! mat = cost(Apos,Bpos,n)   
    ! write(*,"(10(F5.3,X))") mat   
    ! call munkres(dmin,map,cost(Apos,Bpos,n),n)

  end subroutine fastoptimization

end module transform
