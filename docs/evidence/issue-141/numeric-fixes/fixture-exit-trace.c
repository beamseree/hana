#include <execinfo.h>
#include <stdlib.h>
#include <unistd.h>
static void trace_fixture_exit(void) {
    static const char message[] = "[fixture-exit] atexit backtrace\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    void *frames[80];
    int count = backtrace(frames, 80);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
}
__attribute__((constructor)) static void install_fixture_exit_trace(void) {
    atexit(trace_fixture_exit);
}
