! Minimal reproducer: derived-type + contained-subroutine + intent(inout) state.
program repro
    use iso_fortran_env, only: int64
    implicit none

    type :: t_rng
        integer(int64) :: s(4) = 0_int64
    end type t_rng

    type(t_rng) :: rng
    call init_rng(rng, 12345)
    print '(A,Z16.16)', 's(1) = 0x', rng%s(1)
    print '(A,Z16.16)', 's(2) = 0x', rng%s(2)
    print '(A,Z16.16)', 's(3) = 0x', rng%s(3)
    print '(A,Z16.16)', 's(4) = 0x', rng%s(4)
    if (rng%s(1) == rng%s(3) .and. rng%s(2) == rng%s(4)) then
        print *, 'BUG: s(1)==s(3) and s(2)==s(4) (degenerate state)'
        stop 1
    else
        print *, 'OK: four distinct state words'
    end if

contains

    subroutine splitmix64(state, z)
        integer(int64), intent(inout) :: state
        integer(int64), intent(out)   :: z
        state = state + int(z'9e3779b97f4a7c15', int64)
        z = state
        z = ieor(z, ishft(z, -30)) * int(z'bf58476d1ce4e5b9', int64)
        z = ieor(z, ishft(z, -27)) * int(z'94d049bb133111eb', int64)
        z = ieor(z, ishft(z, -31))
    end subroutine splitmix64

    subroutine init_rng(rng, seed)
        type(t_rng), intent(inout) :: rng
        integer, intent(in) :: seed
        integer(int64) :: sm_state
        sm_state = int(seed, int64)
        call splitmix64(sm_state, rng%s(1))
        call splitmix64(sm_state, rng%s(2))
        call splitmix64(sm_state, rng%s(3))
        call splitmix64(sm_state, rng%s(4))
    end subroutine init_rng

end program repro
