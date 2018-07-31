module transform

  use hungarian

  implicit none

  public :: &
       trans, &
       center, &
       fastoptimization, &
       canonicalize

  private :: &
       eye, &
       init_random_seed, &
       norm, &
       det, &
       free_trans, &
       cost_map, &
       analytical_gd_rot, &
       analytical_gd_free, &
       analytical_gd_slant, &
       gradient_descent_explore, &
       classify, &
       ! minimize_classes, &
       pi

  double precision, parameter :: &
       pi = 3.141592653589793d0

contains

  subroutine init_random_seed()
    ! Copied form the GCC docs: https://gcc.gnu.org/onlinedocs/gcc-4.6.4/gfortran/RANDOM_005fSEED.html#RANDOM_005fSEED

    use omp_lib

    INTEGER :: i, n, clock
    INTEGER, DIMENSION(:), ALLOCATABLE :: seed

    CALL RANDOM_SEED(size = n)
    ALLOCATE(seed(n))

    CALL SYSTEM_CLOCK(COUNT=clock)

    seed = clock + OMP_get_thread_num() * 37 * (/ (i - 1, i = 1, n) /)

    CALL RANDOM_SEED(PUT = seed)

    DEALLOCATE(seed)

  end subroutine init_random_seed

  subroutine trans(pos,n,angles,vec)

    integer, intent(in) :: &
         n ! Number of atoms

    double precision, intent(inout), dimension(3,n) :: &
         pos  ! position matrix

    double precision, intent(in), dimension(3,1) :: &
         vec     ! Translation vector

    double precision, dimension(3) :: &
         tvec    ! displacement from origin

    double precision, intent(in), dimension(3) :: &
         angles    ! angle of rotation

    tvec = vec(:,1) + sum(pos,2) / size(pos,2)

    call center(pos,n)

    pos = free_trans(pos, rot_mat(angles), tvec)

  end subroutine trans

  function rot_mat(angles) result(R)

    double precision, intent(in), dimension(3) :: &
         angles     ! Rotation axis (unitary vector)

    double precision, dimension(3,1) :: &
         u     ! Rotation axis (unitary vector)

    double precision, dimension(3,3) :: &
         Q, & ! cross product matrix
         P    ! u.u**T

    double precision, dimension(3,3) :: &
         R    ! Transformation matrix

    u(1,1) = sin(angles(2)) * cos(angles(3))
    u(2,1) = sin(angles(2)) * sin(angles(3))
    u(3,1) = cos(angles(2))

    P = matmul(u,transpose(u))
    Q = transpose(reshape((/0.0d0,-u(3,1),u(2,1),u(3,1),0.0d0,-u(1,1),-u(2,1),u(1,1),0.0d0/),(/3,3/)))

    R = P + (eye() - P)*cos(angles(1)) + Q*sin(angles(1))

  end function rot_mat

  subroutine classify(n, n_classes, classes_list, disps, tol)

    double precision, intent(in), dimension(:,:) :: &
         disps

    double precision, dimension(size(disps,1),size(disps,2)) :: &
         classes

    integer, intent(out), dimension(size(disps,2)) :: &
         classes_list

    double precision, intent(in) :: &
         tol
         
    integer, intent(out), dimension(size(disps,2)) :: &
         n_classes
    
    integer, intent(out) :: &
         n

    logical :: &
         classified

    integer :: &
         i,j

    classes(:,1) = disps(:,1)
    n_classes = 1
    n = 1
    classes_list = 1
    do i=2,size(disps,2)
       classified = .false.
       do j=1,n
          ! if (abs(norm(classes(:,j)) - &
          !      dot_product(classes(:,j), disps(:,i)) / norm(classes(:,j))) < tol & 
          !      .and. norm(classes(:,j))**2*norm(disps(:,i))**2 - &
          !      dot_product(classes(:,j), disps(:,i))/norm(classes(:,j)) < tol) then

          if (norm(classes(:,j) - disps(:,i)) < tol) then

             classes(:,j) = (n_classes(j)*classes(:,j) + disps(:,i)) / (n_classes(j) + 1)
             n_classes(j) = n_classes(j) + 1
             classes_list(i) = j
             classified = .true.
             exit
          endif
       enddo

       if (.not. classified) then
        n = n + 1    
        classes(:,n) = disps(:,i)
        classes_list(i) = n
       endif
  enddo

  end subroutine classify

  subroutine canonicalize(can_mat,tmat)

    double precision, dimension(3) :: &
         u_per     ! Vector perpendicular to the 2 first vectors

    double precision, intent(out), dimension(3,3) :: &
         can_mat ! Rotated (canonical) matrix

    double precision, intent(in), dimension(3,3) :: &
         tmat    ! Transformed matrix to rotate

    can_mat(:,1) = norm(tmat(:,1))*(/1,0,0/)
    
    u_per = tmat(:,2) -  tmat(:,1)*dot_product(tmat(:,1), tmat(:,2))/norm(tmat(:,1))**2
    
    can_mat(:,2) = (/ dot_product(tmat(:,1), tmat(:,2))/norm(tmat(:,1)), &
         norm(u_per), 0.0d0/)
    
    can_mat(:,3) = (/ dot_product(tmat(:,1), tmat(:,3))/norm(tmat(:,1)), &
         dot_product(u_per, tmat(:,3))/norm(u_per), &
         det(tmat,3)/(norm(tmat(:,1))*norm(u_per))/)

    ! This is to avoid seeing an inversion in 2D as a rotation in a           
    ! prohibited axis. This is not necessary in 3D (but not wrong)            
    can_mat(2,:) = can_mat(3,3)/abs(can_mat(3,3))*can_mat(2,:)
    can_mat(3,3) = abs(can_mat(3,3))
    
  end subroutine canonicalize  

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

  function cost_map(Apos,Bpos, n_A, n_B) result(cost)

    double precision, intent(in), dimension(:,:) :: &
         Apos, Bpos  ! Rotation axis
    integer, intent(in) :: &
         n_A, n_B
    double precision, dimension(size(Apos,2),size(Apos,2)) :: &
         cost
    integer :: &
         i,j,n ! Iterators

    cost = 0

    do i=1,size(Apos,2)
       do j=1,size(Bpos,2)
          if (j <= n_B) then
             cost(i,j) = norm(Apos(:,i)-Bpos(:,j))
          elseif (i <= n_A) then  
             cost(i,j) = 1000 ! TODO: Should that be a param?
          endif
       enddo
    enddo

  end function cost_map

  subroutine mapping(Apos_mapped, Bpos_opt, Apos, Bpos, tBpos, fracA, fracB, atoms, n_atoms)
    
    integer, intent(in) :: &
         n_atoms ! Number of types of atoms
    double precision, intent(in), dimension(:,:) :: &
         Apos, Bpos, tBpos  ! position matrix
    integer, intent(in), dimension(n_atoms) :: &
         atoms
    double precision, intent(in) :: &
         fracA, fracB
    double precision, intent(out), &
         dimension(3,int(fracB*size(Apos,2)/sum(atoms))*sum(atoms)) :: &
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
         n, n_A, n_B

    An_cell = size(Apos,2)/sum(atoms)

    id = 0
    idx = 0
    n = 0

    do i=0,n_atoms-1

       id = id + n

       n = An_cell*atoms(i+1)
       n_B = int(An_cell*fracB)*atoms(i+1)
       n_A = int(An_cell*fracA)*atoms(i+1)

       allocate(dmat(n,n), map(n))

       dmat = cost_map(Apos( : , id + 1 : id + n ), &
            tBpos( : , id + 1 : id + n ),n_A, n_B)

       call munkres(dist_map, map, dmat, n)
       
       map = map + id

       do l=1, int(n*fracB)
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

  ! subroutine minimize_classes(tmat, vec, Apos, Bpos, n_iter, rate1, rate2)
  !   integer, intent(in) :: &
  !        n_iter ! Number of atoms

  !   double precision, intent(in) :: &
  !        rate1, & ! Rate for angles
  !        rate2    ! Rate for disp

  !   double precision, intent(in), dimension(:,:) :: &
  !        Apos, &
  !        Bpos ! Bpos ordered according to the mapping

  !   double precision, intent(inout), dimension(3,3) :: &         
  !        tmat     ! Transformation matrix

  !   double precision, dimension(3,3) :: &         
  !        tmat_tmp, &
  !        tmat_grad

  !   double precision, intent(inout), dimension(3) :: &         
  !        vec       ! Translation vector
    
  !       double precision, dimension(3) :: &         
  !        vec_tmp, &
  !        vec_grad

  !   integer :: &
  !        i, j, k, l, & ! Iterator
  !        n_class, &
  !        n_class_cur

  !   double precision, parameter :: &
  !        tol = 1d-3, &
  !        dt = 1d-5, &
  !        n_ex = 100

  !   call init_random_seed()

  !   do i=1,n_iter
  !      do j=1,3
  !         do k = 1,3
  !            tmat_tmp = tmat
  !            l = 0
  !            do while (n_class_cur >= n_class .and. l < n_ex)  
  !               l=l+1             
  !               tmat_tmp(j,k) = tmat_tmp(j,k) + dt 
  !               n_class_cur = classify(Apos - free_trans(Bpos,tmat_tmp,vec), tol)
  !               print*, l, n_class_cur - n_class
  !            enddo
  !            if (n_class_cur < n_class) then
  !               tmat = tmat_tmp
  !               n_class = n_class_cur
  !            else
  !               tmat_tmp = tmat
  !               l = 0
  !               do while (n_class_cur >= n_class .and. l < n_ex)  
  !                  l=l+1             
  !                  tmat_tmp(j,k) = tmat_tmp(j,k) - dt 
  !                  n_class_cur = classify(Apos - free_trans(Bpos,tmat_tmp,vec), tol)
  !                  print*, -l, n_class_cur - n_class
  !               enddo
  !               if (n_class_cur < n_class) then
  !                  tmat = tmat_tmp
  !                  n_class = n_class_cur
  !               endif
  !            endif
  !         enddo
  !      enddo

  !      ! do k = 1,3
  !      !    vec_tmp = vec 
  !      !    vec_tmp(k) = vec(k) + dt 
  !      !    vec_grad(k) = (classify(Apos - free_trans(Bpos,tmat,vec_tmp),tol) &
  !      !         - classify(Apos - free_trans(Bpos,tmat,vec),tol)) / dt
  !      ! enddo

  !      ! tmat = tmat - rate1 * tmat_grad
  !      ! vec = vec - rate2 * vec_grad

  !      print*, classify(Apos - free_trans(Bpos,tmat,vec_tmp),tol)


  !      ! do j=1,3
  !      !    do k = 1,3
  !      !       tmat_tmp = tmat 
  !      !       tmat_tmp(j,k) = tmat(j,k) + dt 
  !      !       tmat_grad(j,k) = (classify(Apos - free_trans(Bpos,tmat_tmp,vec), tol) &
  !      !            - classify(Apos - free_trans(Bpos,tmat,vec),tol)) / dt
  !      !    enddo
  !      ! enddo

  !      ! do k = 1,3
  !      !    vec_tmp = vec 
  !      !    vec_tmp(k) = vec(k) + dt 
  !      !    vec_grad(k) = (classify(Apos - free_trans(Bpos,tmat,vec_tmp),tol) &
  !      !         - classify(Apos - free_trans(Bpos,tmat,vec),tol)) / dt
  !      ! enddo

  !      ! print*, "TMAT GRAD"
  !      ! write(*,"(3(F10.5,X))") rate1 * tmat_grad
  !      ! print*, "VEC GRAD"
  !      ! write(*,"(3(F10.5,X))") rate2 * vec_grad

  !      ! tmat = tmat - rate1 * tmat_grad
  !      ! vec = vec - rate2 * vec_grad

  !      ! print*, classify(Apos - free_trans(Bpos,tmat,vec_tmp),tol)

  !   !    call random_number(tmat_grad)
  !   !    tmat_grad = 0.1 * rate1 * tmat_grad

  !   !    write(*,"(3(E10.5,X))") tmat_grad
  !   !    print*, classify(Apos - free_trans(Bpos,tmat+tmat_grad,vec),tol)

  !   !    if (classify(Apos - free_trans(Bpos,tmat+tmat_grad,vec),tol) < &
  !   !         classify(Apos - free_trans(Bpos,tmat,vec),tol)) then
  !   !       tmat = tmat + tmat_grad
  !   !    endif

  !   !    call random_number(vec_grad)
  !   !    vec_grad = rate2 * vec_grad

  !   !    if (classify(Apos - free_trans(Bpos,tmat,vec + vec_grad),tol) < &
  !   !         classify(Apos - free_trans(Bpos,tmat,vec),tol)) then
  !   !       vec = vec + vec_grad
  !   !    endif

  !   !    print*, classify(Apos - free_trans(Bpos,tmat,vec),tol)

  !   enddo

    

  ! end subroutine minimize_classes

  subroutine analytical_gd_slant(slant, vec, Apos, Bpos, n_iter, rate1, rate2)

    integer, intent(in) :: &
         n_iter ! Number of atoms

    double precision, intent(in) :: &
         rate1, & ! Rate for angles
         rate2    ! Rate for disp

    double precision, intent(in), dimension(:,:) :: &
         Apos, &
         Bpos ! Bpos ordered according to the mapping

    double precision, intent(out), dimension(3,3) :: &         
         slant     ! Transformation matrix

    double precision, intent(inout), dimension(3,1) :: &         
         vec       ! Translation vector

    double precision, dimension(3,size(Bpos,2)) :: &
         E ! position matrix

    double precision, dimension(3,1) :: &         
         v1, v2, & ! Vectors of the plane of slanting
         dv1d1, &  ! Derivative of the plane vector
         dv1d2, &
         dv2d1, &
         dv2d2, &
         dv2d3

    double precision, dimension(3) :: &
         angles    ! 3 vectors of the rotation: 1. angle of rotation 2&3. Spherical angles of the axis of rotation

    double precision, dimension(3,3) :: &
         M1, M2, M3, Mk

    double precision, dimension(size(Bpos,2),1) :: &
         ones

    double precision :: &
         dist, &
         dist_prev, &
         s1, s2, s3, & ! Sine of angles
         c1, c2, c3, & ! Cosine of angles
         k ! Slanting factor

    integer :: &
         i, j ! Iterator

    double precision, parameter :: &
         tol = 1d-10

    ones = 1.0d0

    call init_random_seed()

    ! call random_number(angles)

    ! angles = (/0.0d0, pi/2.0d0, pi/2.0d0/) 

    angles = 0.0d0

    k = 1.0d0

    slant = eye()
    dist = 0
    dist_prev = tol+1

    j=0
    do while (j < n_iter .and. abs(dist - dist_prev) > tol)
       j=j+1

       s1 = sin(angles(1))
       s2 = sin(angles(2))
       s3 = sin(angles(3))
       c1 = cos(angles(1))
       c2 = cos(angles(2))
       c3 = cos(angles(3))

       v1 = reshape((/s2*c1, s2*s1, c2/),(/3,1/))

       v2 = reshape((/s3*c2*c1-c3*s1, &
            s3*c2*s1+c3*c1, &
            -s3*s2/),(/3,1/))       

       dv1d1 = reshape((/-s2*s1, s2*c1, 0.0d0/),(/3,1/))
       dv1d2 = reshape((/c2*c1, c2*s1, -s2/),(/3,1/))

       dv2d1 = reshape((/-s3*c2*s1 - c3*c1, &
               s3*c2*c1 - c3*s1, &
               0.0d0/),(/3,1/))
       dv2d2 = reshape((/-s3*s2*c1, &
               -s3*s2*s1, &
               -s3*c2/),(/3,1/))
       dv2d3 = reshape((/c3*c2*c1 + s3*s1, &
               c3*c2*s1 - s3*c1, &
               -c3*s2/),(/3,1/))

       slant = k*matmul(v1,transpose(v2)) + eye()

       dist_prev = dist
       dist = sum(sqrt(sum((Apos - free_trans(Bpos,slant,vec))**2,1)))

       E = Apos - free_trans(Bpos,slant,vec)
       E = E / spread(sqrt(sum(E**2,1)),1,3)

       M1 = k * (matmul(dv1d1,transpose(v2)) + matmul(v1, transpose(dv2d1))) 
       M2 = k * (matmul(dv1d2,transpose(v2)) + matmul(v1, transpose(dv2d2)))
       M3 = k * (matmul(v1, transpose(dv2d3)))
       Mk = matmul(v1,transpose(v2))

       angles(1) = angles(1) + rate1 * dist * sum(matmul(E,transpose(Bpos)) * M1)
       angles(2) = angles(2) + rate1 * dist * sum(matmul(E,transpose(Bpos)) * M2)
       angles(3) = angles(3) + rate1 * dist * sum(matmul(E,transpose(Bpos)) * M3)
       k = k + rate1 * 0.01 * dist * sum(matmul(E,transpose(Bpos)) * Mk)
       vec = vec + rate2 * dist * matmul(E,ones)
       
    enddo

    print*, dist

  end subroutine analytical_gd_slant  

  subroutine analytical_gd_rot(angles, vec, Apos, Bpos, n_iter, rate1, rate2)

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
         vec       ! Translation vector

    double precision, dimension(3,1) :: &         
         u         ! Axis of rotation

    double precision, intent(inout), dimension(3) :: &
         angles    ! 3 vectors of the rotation: 1. angle of rotation 2&3. Spherical angles of the axis of rotation

    double precision, dimension(3,3) :: &
         P1, P2, P3, & ! Temporary transformation matrix
         Q1, Q2, Q3, &
         M1, M2, M3, M

    double precision, dimension(size(Bpos,2),1) :: &
         ones

    double precision :: &
         dist, &
         dist_prev, &
         dist_2prev, &
         s2, s3, & ! Sine of angle 1 and 2
         c2, c3    ! Cosine of angle 1 and 2

    integer :: &
         i, j ! Iterator

    double precision, parameter :: &
         tol = 1d-10

    ones = 1.0d0

    dist = 0
    dist_prev = tol+1
    dist_2prev = dist_prev

    j=0
    do while (j < n_iter .and. abs(dist - dist_prev) > tol)
       j=j+1

       M = rot_mat(angles)

       dist_2prev = dist_prev
       dist_prev = dist
       dist = sum(sqrt(sum((Apos - free_trans(Bpos,M,vec))**2,1)))

       E = Apos - free_trans(Bpos,M,vec)
       E = E / spread(sqrt(sum(E**2,1)),1,3)

       s2 = sin(angles(2))
       s3 = sin(angles(3))
       c2 = cos(angles(2))
       c3 = cos(angles(3))

       P2 = transpose(reshape((/2*s2*c2*c3**2, &
            2*s2*c2*s3*c3, &
            (1 - 2*s2**2) * c3, &
            2*s2*c2*s3*c3, &
            2*s2*c2*s3**2, &
            (1 - 2*s2**2) * s3, &
            (1 - 2*s2**2) * c3, &
            (1 - 2*s2**2) * s3, &
            -2*c2*s2/), &
            (/3,3/)))
       Q2 = transpose(reshape((/0.0d0, &
            s2, &
            c2 * s3, &
            -s2, &
            0.0d0, &
            -c2*c3, &
            -c2*s3, &
            c2*c3, &
            0.0d0/), &
            (/3,3/)))

       M2 = P2 - P2*cos(angles(1)) + Q2*sin(angles(1))

       P3 = transpose(reshape((/-2*s2**2*c3*s3, &
            (1 - 2*s3**2) * s2**2, &
            -s2*c2*s3, &
            (1 - 2*s3**2) * s2**2, &
            2*s2**2*s3*c3, &
            s2*c2*c3, &
            -s2*c2*s3, &
            s2*c2*c3, &
            0.0d0/), &
            (/3,3/)))
       Q3 = transpose(reshape((/0.0d0, &
            0.0d0, &
            s2*c3, &
            0.0d0, &
            0.0d0, &
            s2*s3, &
            -s2*c3, &
            -s2*s3, &
            0.0d0/), &
            (/3,3/)))

       M3 = P3 - P3*cos(angles(1)) + Q3*sin(angles(1))

       u(1,1) = sin(angles(2)) * cos(angles(3))
       u(2,1) = sin(angles(2)) * sin(angles(3))
       u(3,1) = cos(angles(2))

       P1 = matmul(u,transpose(u))
       Q1 = transpose(reshape((/0.0d0,-u(3,1),u(2,1),u(3,1),0.0d0,-u(1,1),-u(2,1),u(1,1),0.0d0/),(/3,3/)))

       M1 = P1 - (eye() - P1)*sin(angles(1)) + Q1*cos(angles(1))
              
       angles(1) = angles(1) + rate1 * dist * sum(matmul(E,transpose(Bpos)) * M1)
       angles(2) = angles(2) + rate1 * dist * sum(matmul(E,transpose(Bpos)) * M2)
       angles(3) = angles(3) + rate1 * dist * sum(matmul(E,transpose(Bpos)) * M3)
       vec = vec + rate2 * dist * matmul(E,ones)
              
    enddo


  end subroutine analytical_gd_rot

  subroutine analytical_gd_free(tmat, vec, Apos, Bpos, sq, n_iter, rate1, rate2)

    integer, intent(in) :: &
         n_iter ! Number of atoms

    double precision, intent(in) :: &
         rate1, & ! Rate for angles
         rate2    ! Rate for disp
    
    logical, intent(in) :: &
         sq ! Square distance mode

    double precision, intent(in), dimension(:,:) :: &
         Apos, &
         Bpos ! Bpos ordered according to the mapping

    double precision, dimension(3,size(Bpos,2)) :: &
         E ! position matrix

    double precision, intent(inout), dimension(3,3) :: &         
         tmat     ! Transformation matrix

    double precision, dimension(3,3) :: &         
         ddet ! Determinant matrix (cofactor matrix)
    
    double precision, dimension(2,2) :: &         
         ttmat ! Determinant matrix (similar to cofactor matrix)

    double precision, intent(inout), dimension(3,1) :: &         
         vec     ! Translation vector

    double precision, dimension(size(Bpos,2),1) :: &
         ones

    double precision :: &
         dist, &
         dist_prev

    integer :: &
         j, k, l ! Iterator

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

       if (.not. sq) then
          E = E / spread(sqrt(sum(E**2,1)),1,3)
       endif

       ! do k=1,3
       !    do l=1,3
       !       ttmat(:k-1,:l-1) = tmat(:k-1,:l-1)
       !       ttmat(:k-1,l:) = tmat(:k-1,l+1:)
       !       ttmat(k:,:l-1) = tmat(k+1:,:l-1)
       !       ttmat(k:,l:) = tmat(k+1:,l+1:)
       !       !print*, "ttmat", k,l
       !       !write(*,"(2(F5.3,X))") ttmat
       !       ddet(k,l) = (1-modulo(K+l,2))*det(ttmat,2)
       !    enddo
       ! enddo
       
       !print*, "tmat"
       !write(*,"(3(F5.3,X))") tmat

       !print*, "ddet"
       !write(*,"(3(F5.3,X))") ddet

       tmat = tmat + rate1*dist*matmul(E,transpose(Bpos)) ! old
       ! tmat = tmat + rate1*dist*( matmul(E,transpose(Bpos))/det(tmat,3)**(1.0d0/3.0d0) &
       !     + 1.0d0/3.0d0*dist/det(tmat,3)**(4.0d0/3.0d0)*ddet) ! tmp cubic root version
       ! tmat = tmat + rate1*dist*( matmul(E,transpose(Bpos))/det(tmat,3) &
       !      + dist/det(tmat,3)**2*ddet) ! tmp 
       vec = vec + rate2*dist*matmul(E,ones)

    enddo

  end subroutine analytical_gd_free
  
  subroutine analytical_gd_std(std, tmat, vec, Apos, Bpos, n_classes, classes, n_iter, rate1, rate2)

    integer, intent(in) :: &
         n_iter ! Number of atoms

    double precision, intent(in) :: &
         rate1, & ! Rate for angles
         rate2    ! Rate for disp

    double precision, intent(in), dimension(:,:) :: &
         Apos, &
         Bpos ! Bpos ordered according to the mapping

    double precision, allocatable, dimension(:,:) :: &
         E ! position matrix

    integer, intent(in), dimension(:) :: &
         n_classes
    
    integer, intent(in), dimension(:) :: &
         classes

    double precision, intent(inout), dimension(3,3) :: &         
         tmat     ! Transformation matrix

    double precision, dimension(3,3) :: &         
         ddet ! Determinant matrix (cofactor matrix)
    
    double precision, dimension(2,2) :: &         
         ttmat ! Determinant matrix (similar to cofactor matrix)

    double precision, intent(inout), dimension(3,1) :: &         
         vec     ! Translation vector
    
    double precision, allocatable, dimension(:,:) :: &
         Apos_class, &
         Bpos_class

    double precision, dimension(3,3) :: &         
         tmat_grad     ! Transformation matrix

    double precision, dimension(3,1) :: &         
         vec_grad      ! Translation vector

    double precision, allocatable, dimension(:,:) :: &
         ones

    double precision :: &
         std, &
         std_prev

    integer :: &
         j, k, l, i ! Iterator

    double precision, parameter :: &
         tol = 1d-10

    print*, n_classes

    std = 1.0d0
    std_prev = 2.0d0+tol

    j=0
    do while (j < n_iter .and. abs(std - std_prev) > tol)
       j=j+1

       std_prev = std

       tmat_grad = 0.0d0
       vec_grad = 0.0d0
       std = 0.0d0
       do i=1,size(n_classes)
          allocate(Apos_class(3,n_classes(i)), Bpos_class(3,n_classes(i)), &
               ones(1,n_classes(i)), E(3,n_classes(i)))
          
          ones = 1.0d0

          l=0
          do k=1,size(classes)
             if (classes(k) == i) then
                l=l+1
                Apos_class(:,l) = Apos(:,k)
                Bpos_class(:,l) = Bpos(:,k)
             endif
          enddo
          
          std = std + sum((Apos_class - free_trans(Bpos_class,tmat,vec))**2) - &
               norm(sum(Apos_class - free_trans(Bpos_class,tmat,vec),2))**2/size(Apos_class,2)

          E = Apos_class - free_trans(Bpos_class,tmat,vec)
          E = E - matmul(reshape(sum(E,2),(/3,1/))/size(E,2), ones)

          tmat_grad = tmat_grad + rate1*std_prev*matmul(E,transpose(Bpos_class))
          vec_grad = vec_grad + rate2*std_prev*matmul(E,transpose(ones))

          deallocate(Apos_class, Bpos_class, ones, E)
       enddo
       
       tmat = tmat + tmat_grad
       vec = vec + vec_grad

    enddo

  end subroutine analytical_gd_std
  
  subroutine gradient_descent_explore(angles, vec, Apos, Bpos, cell, icell, &
       fracA, fracB, atoms, n_atoms, n_iter, n_ana, n_conv, rate1, rate2)
    ! New Gradient Descent Random

    use omp_lib

    integer, intent(in) :: &
         n_iter, n_atoms, & ! Number of atoms
         n_ana, &
         n_conv

    double precision, intent(in) :: &
         rate1, & ! Rate for angles
         rate2, & ! Rate for disp
         fracA, fracB ! Fraction of A and B to use in optimisation

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

    double precision, dimension(3,int(fracB*size(Apos,2)/sum(atoms))*sum(atoms)) :: &
         Apos_mapped, & ! position matrix
         Apos_mapped_prev, &
         Bpos_opt
    
    double precision, intent(out), dimension(3) :: &
         vec, &     ! Translation vector
         angles     ! Angles of rotation

    double precision, dimension(3) :: &
         vec_local, &     ! Translation vector
         angles_local

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
         diag

    double precision, allocatable, dimension(:) :: &
         dist_min

    double precision, allocatable, dimension(:,:) :: &
         angles_min, &
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

    mul_vec = diag*2/sqrt(3.0d0)
    
    !$omp parallel default(private) shared(dist_min, &
    !$omp angles_min, vec_min, angles, vec) &
    !$omp firstprivate(n_iter, mul_vec, cell, fracA, fracB, &
    !$omp icell, n_conv, n_ana, Apos, Bpos, rate1, rate2, atoms, n_atoms)

    call init_random_seed()
    
    n_threads = OMP_get_num_threads()

    !$omp single
    allocate(dist_min(n_threads), &
         angles_min(3,n_threads), &
         vec_min(3,n_threads))
    !$omp end single

    thread = OMP_get_thread_num() + 1
    
    dist_min(thread) = sum(sqrt(sum((Apos - Bpos)**2,1)))
    
    !$omp do
    do j=1, n_iter
       
       call random_number(angles_local)
       call random_number(vec_local)

       angles_local = angles_local*2*pi

       vec_local = vec_local - (/0.5d0,0.5d0,0.5d0/)

       vec_local = vec_local*mul_vec
       
       vec_local = vec_local - matmul(cell,nint(matmul(icell,vec_local))) 

       write(*,*) "New initial step", thread, j, "Angles", angles_local
       
       Apos_mapped = 1.0d0
       Apos_mapped_prev = 0.0d0
       k=1

       do while ( k <= n_conv .and. any(Apos_mapped /= Apos_mapped_prev))
          k=k+1

          Apos_mapped_prev = Apos_mapped
          
          tBpos = free_trans(Bpos,rot_mat(angles_local),vec_local)

          call mapping(Apos_mapped, Bpos_opt, Apos, Bpos, tBpos, &
               fracA, fracB, atoms, n_atoms)

          call analytical_gd_rot(angles_local, vec_local, Apos_mapped, Bpos_opt, &
               n_ana, rate1, rate2)

       enddo

       dist_cur = sum(sqrt(sum((Apos_mapped - free_trans(Bpos_opt,rot_mat(angles_local),vec_local))**2,1)))

       print*, "Opt dist", dist_cur

       if (dist_cur < dist_min(thread)) then
          dist_min(thread) = dist_cur
          angles_min(:,thread) = angles_local
          vec_min(:,thread) = vec_local
       endif

    enddo
    !$omp end do
    !$omp barrier
    !$omp single

    pos = minloc(dist_min, 1)
    print*, "Shortest dist", dist_min(pos)
    
    angles = angles_min(:,pos)
    vec = vec_min(:,pos)

    deallocate(dist_min, &
         angles_min,&
         vec_min)
    !$omp end single 
    
    !$omp end parallel

  end subroutine gradient_descent_explore

  subroutine fastoptimization(Apos_out, Bpos_out, Bpos_out_stretch, & ! Output
       n_out, classes_list_out, & ! Output
       tmat, dmin, & ! Output
       Apos, na, Bpos, nb, &
       fracA, fracB, Acell, iAcell, atoms, n_atoms, &
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
         fracA, fracB ! Fraction of A and B to use in optimisation

    double precision, allocatable, dimension(:,:) :: &
         inBpos ! Position of the atoms

    integer, intent(in), dimension(n_atoms) :: &
         atoms !Number of atoms of each type

    double precision, intent(out) :: &
         dmin

    double precision, dimension(3) :: &
         vec, &     ! Translation vecto
         vec_rot, & ! Translation vector for the rotated unstretched matrix
         angles, &  ! Rotation angles
         center_vec ! Readjustment vector

    double precision :: &
         d, &
         dist_map, &
         dist_stretch, &
         std, std_prev, &
         tol_adjust

    double precision, allocatable, dimension(:,:) :: &
         dmat

    double precision, dimension(na,nb) :: &
         mat

    double precision, intent(out), dimension(3,3) :: &
         tmat ! Transformation matrix

    double precision, dimension(3,3) :: &
         slant, & ! Transformation matrix
         testmat

    double precision, &
         dimension(3,int(fracB*size(Apos,2)/sum(atoms))*sum(atoms)) :: &
         Apos_mapped, Bpos_opt, &
         tBpos_opt, &
         rBpos_opt, &
         Bpos_opt_stretch  ! position matrix

    integer, intent(out), dimension(size(Apos,2)) :: &         
         classes_list_out

    integer, &
         dimension(int(fracB*size(Apos,2)/sum(atoms))*sum(atoms)) :: &
         classes_list, &
         classes_list_prev
    
    integer, &
         dimension(int(fracB*size(Apos,2)/sum(atoms))*sum(atoms)) :: &
         n_classes_trail

    integer :: &
         n
    
    integer, allocatable, dimension(:) :: &
         n_classes

    integer :: &
         i, j, &
         id, &
         An_cell, Bn_cell

    double precision, parameter :: &
         pi = 3.141592653589793d0, &
         tol = 1.0d-5

    n_out = int(fracB*size(Apos,2)/sum(atoms))*sum(atoms)
    Apos_out = 0
    Bpos_out = 0

    ! Center both cells at the geometric center
    call center(Bpos,nb)
    call center(Apos,na)

    call gradient_descent_explore(angles, vec, Apos, Bpos, Acell, iAcell, &
         fracA, fracB, atoms,n_atoms,n_iter, n_ana, n_conv, rate1, rate2)

    angles = (/ 0.0d0, 0.0d0, 0.0d0 /)

    vec = (/ 0.25d0, 0.25d0, 0.0d0 /)

    tmat = rot_mat(angles)

    write(*,*) "/======== Stretching Adjustment ========\\"
    
    do i=1,n_adjust

       do j=1,n_conv
       
          tBpos = free_trans(Bpos,tmat,vec)

          call mapping(Apos_mapped, Bpos_opt, Apos, Bpos, tBpos, &
               fracA, fracB, atoms, n_atoms)

          angles = 0
          tBpos_opt = free_trans(Bpos_opt,tmat,(/0.0d0,0.0d0,0.0d0/))
          
          call analytical_gd_rot(angles, vec, Apos_mapped, tBpos_opt, &
               n_ana*100, rate1, rate2)
          
          tmat = matmul(rot_mat(angles),tmat)

       enddo

       vec_rot = vec
       
       ! This step is just to get the "unstretched distance"
       call analytical_gd_rot(angles, vec_rot, Apos_mapped, Bpos_opt, &
               n_ana*1000, rate1, rate2)

       write(*,*) "-->", i

       write(*,*) "Stretched distance:", sum(sqrt(sum((Apos_mapped - free_trans(Bpos_opt, tmat, vec))**2,1)))

       write(*,*) "Unstretched distance:", sum(sqrt(sum((Apos_mapped - free_trans(Bpos_opt, rot_mat(angles), vec_rot))**2,1)))

       call analytical_gd_free(tmat, vec, Apos_mapped, Bpos_opt,.false., n_ana*100, rate1, rate2)
       
       
    enddo

    ! call minimize_classes(tmat, vec, Apos_mapped, Bpos_opt, 100000, 1d-2, 1d-2)

    rBpos_opt = free_trans(Bpos_opt, rot_mat(angles), vec_rot)

    write(*,*) "/======== Deslanting ========\\"

    do i=1, n_adjust

       write(*,*) "-->", i

       tBpos_opt = free_trans(Bpos_opt, tmat, (/0.0d0,0.0d0,0.0d0/))

       angles = 0.0d0

       call analytical_gd_rot(angles, vec_rot, rBpos_opt, tBpos_opt, &
            n_ana*1000, rate1, rate2)

       tBpos_opt = free_trans(tBpos_opt, rot_mat(angles), (/0.0d0,0.0d0,0.0d0/))

       tmat = matmul(rot_mat(angles), tmat)

       call analytical_gd_slant(slant, vec, rBpos_opt, tBpos_opt, n_ana*1000, rate1, rate2)
       
       tmat = matmul(slant, tmat)
       
    enddo

    write(*,*) "/======== Classification ========\\"

    tol_adjust = 1.0d0
    std = 1.0d0
    classes_list = 0
    classes_list_prev = 1
    j=0
    do while ( std > tol .or. any(classes_list /= classes_list_prev))
       j = j + 1
       
       write(*,*) "-->", j

       classes_list_prev = classes_list
       std_prev = std

       n = size(Apos_mapped,2)
       do while (n == size(Apos_mapped,2))
          tol_adjust = tol_adjust / 2.0d0
          call classify(n, n_classes_trail, classes_list, Apos_mapped-free_trans(Bpos_opt,tmat,vec), tol_adjust)
       enddo

       allocate(n_classes(n))

       do i=1,n
          n_classes(i) = n_classes_trail(i)
       enddo

       call analytical_gd_std(std, tmat, vec, Apos_mapped, Bpos_opt, &
            n_classes, classes_list, n_ana*1000, rate1, rate2)

       deallocate(n_classes)

       write(*,*) "Tolerance for classification:", tol_adjust
       write(*,*) "Final standard deviation:", std

       tol_adjust = 3*sqrt(abs(std)) !3 sigma 99%

    enddo

    classes_list_out = 0
    classes_list_out(1:n_out) = classes_list

    write(*,*) "Final tmat"
    write(*,"(3(F7.3,X))") tmat

    ! Recenter
    center_vec = sum(free_trans(Bpos_opt,rot_mat(angles),vec) - Apos_mapped,2) / n_out
    
    Bpos_opt_stretch = free_trans(Bpos_opt,tmat,vec + center_vec)

    Bpos_opt = free_trans(rBpos_opt, eye(), center_vec)

    Bpos_out(:,1:n_out) = Bpos_opt
    Bpos_out_stretch(:,1:n_out) = Bpos_opt_stretch
    Apos_out(:,1:n_out) = Apos_mapped

    dmin = sum(sqrt(sum((Apos_mapped - Bpos_opt)**2,1)))

    ! ! Print the cost matrix
    ! mat = cost(Apos,Bpos,n)   
    ! write(*,"(10(F5.3,X))") mat

  end subroutine fastoptimization

end module transform
