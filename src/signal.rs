use std::ptr;

pub fn prevent_zombie_processes() {
    unsafe {
        let mut sa: libc::sigaction = std::mem::zeroed();
        libc::sigemptyset(&mut sa.sa_mask);
        sa.sa_flags = libc::SA_NOCLDSTOP | libc::SA_NOCLDWAIT | libc::SA_RESTART;
        sa.sa_sigaction = libc::SIG_IGN;
        libc::sigaction(libc::SIGCHLD, &sa, ptr::null_mut());

        while libc::waitpid(-1, ptr::null_mut(), libc::WNOHANG) > 0 {}
    }
}
