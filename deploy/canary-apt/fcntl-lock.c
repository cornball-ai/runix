/* fcntl-lock: VM-only, uninstalled test helper for the lock-contention gate. It
 * takes a POSIX fcntl (F_SETLK) WRITE lock on a file and holds it, so it excludes
 * apt's own GetLock — which uses fcntl record locks, NOT flock (a flock and an
 * fcntl lock on the same file do not conflict, which is why `flock(1)` cannot drive
 * this gate). It prints "locked" once the lock is held (so the caller can wait for
 * readiness) and holds it for `seconds`. Built in-guest by install-apt-stack.sh.
 *
 *   fcntl-lock <path> <seconds>
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: fcntl-lock <path> <seconds>\n");
        return 2;
    }
    int fd = open(argv[1], O_RDWR | O_CREAT, 0640);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    struct flock fl;
    memset(&fl, 0, sizeof fl);
    fl.l_type = F_WRLCK; /* the same conflicting mode apt's GetLock requests */
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0; /* whole file */
    if (fcntl(fd, F_SETLK, &fl) != 0) {
        perror("F_SETLK");
        return 1;
    }
    printf("locked %s\n", argv[1]);
    fflush(stdout);
    unsigned secs = (unsigned) strtoul(argv[2], NULL, 10);
    sleep(secs);
    return 0;
}
