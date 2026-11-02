// Spike: boots plain OTP (start_clean) from an iOS app bundle, with fork()
// failing as the device sandbox makes it fail. Prints what it finds and
// halts. Throwaway: the real host is native/baguette_host.
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void erl_start(int argc, char **argv);

// The device sandbox denies fork(); make the simulator do the same, so the
// spike proves the device's boot path. The executable's own definition wins
// over libSystem's for every reference linked into it.
pid_t fork(void) {
    fprintf(stderr, "baguette: fork() refused\n");
    errno = EPERM;
    return -1;
}

int main(void) {
    char exe[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0) return 1;
    char real[PATH_MAX];
    realpath(exe, real);
    char root[PATH_MAX], bindir[PATH_MAX], boot[PATH_MAX];
    snprintf(root, sizeof root, "%s/otp", dirname(real));
    snprintf(bindir, sizeof bindir, "%s/bin", root);
    snprintf(boot, sizeof boot, "%s/bin/start_clean", root);

    setenv("BINDIR", bindir, 1);
    setenv("ROOTDIR", root, 1);
    setenv("EMU", "beam", 1);
    setenv("PROGNAME", "erl", 1);
    const char *home = getenv("HOME");
    if (!home) home = "/tmp";
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("baguette: booting OTP at %s\n", root);

    const char *eval =
        "io:format(\"baguette: BEAM up, ~s~n\", [erlang:system_info(system_version)]),"
        "io:format(\"baguette: os:cmd -> ~p~n\", [catch os:cmd(\"true\")]),"
        "io:format(\"baguette: open_port spawn -> ~p~n\", [catch open_port({spawn, \"true\"}, [])]),"
        "io:format(\"baguette: crypto -> ~p~n\", [catch crypto:info_lib()]),"
        "io:format(\"baguette: sha256 -> ~p~n\", [catch binary:encode_hex(crypto:hash(sha256, <<\"baguette\">>))]),"
        "io:format(\"baguette: asn1 -> ~p~n\", [catch asn1rt_nif:decode_ber_tlv(<<2,1,1>>)]),"
        "io:format(\"baguette: spike ok~n\"),"
        "erlang:halt(0).";
    char *args[] = {
        "beam", "-fnu", "--",
        "-root", root, "-bindir", bindir, "-progname", "erl", "--",
        "-home", (char *)home, "--",
        "-noshell", "-boot", boot,
        "-eval", (char *)eval,
        NULL,
    };
    erl_start(sizeof args / sizeof args[0] - 1, args);
    return 0;
}
