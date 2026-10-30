/* monotonic_stub.c — a clock no NTP step moves, for masc-exec-shim.
 *
 * ocaml_shim_monotonic_seconds : unit -> float
 *
 * Seconds from an unspecified origin, read from CLOCK_MONOTONIC. Only
 * differences between two readings mean anything; the origin is not a wall
 * time and must not be reported as one.
 *
 * Why a stub rather than mtime: the shim's production artifact is built by
 * scripts/build-shim-static.sh in a container carrying dune, yojson and
 * base64 and nothing else. A new opam dependency would grow that list for
 * every future build of the guest binary; clock_gettime is in libc on both
 * targets (musl always, macOS since 10.12), so this costs nothing at the
 * link.
 *
 * Why the shim needs it: supervise() decides when to kill the payload, how
 * long to drain its pipes after the reap, and how long to wait before
 * SIGKILL. Those were differences of Unix.gettimeofday readings, which
 * measure the wall clock and therefore also measure any correction it took
 * in between. A forward step kills a command that is running fine and
 * reports it as a timeout, and cuts the drain short so the tool output comes
 * back truncated; a backward step withholds the deadline and the shim sits.
 */
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <time.h>

CAMLprim value ocaml_shim_monotonic_seconds(value vunit)
{
  CAMLparam1(vunit);
  struct timespec ts;
  /* CLOCK_MONOTONIC is mandatory in POSIX.1-2008 and present on both
     targets. A failure here is not something the caller can work around --
     falling back to the wall clock would silently restore the defect this
     exists to remove -- so it raises. */
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    caml_failwith("clock_gettime(CLOCK_MONOTONIC)");
  CAMLreturn(caml_copy_double((double)ts.tv_sec + (double)ts.tv_nsec * 1e-9));
}
