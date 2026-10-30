/* prctl_stub.c — Linux prctl + signal-number helpers for masc-exec-shim.
 *
 * ocaml_prctl_set_pdeathsig : unit -> unit
 *
 * On Linux: prctl(PR_SET_PDEATHSIG, SIGKILL) — the kernel SIGKILLs this
 * process when its parent dies, which covers the shim being killed before
 * the payload.  The signal is fixed to SIGKILL in C on purpose: OCaml's
 * Sys.sig* constants are portable abstract codes (negative ints), NOT
 * host OS signal numbers, so taking the signal from OCaml would hand the
 * kernel garbage.  Raises Unix.Unix_error on failure.
 *
 * On non-Linux hosts (macOS dev builds): no-op.  PR_SET_PDEATHSIG is a
 * Linux-specific prctl; everywhere else the shim's process-group kill
 * policy (SIGTERM -> grace -> SIGKILL to the child's pgid) is the primary
 * reaper.  Keeping the stub a no-op lets the same source build on macOS
 * for development while the production artifact is the static musl Linux
 * binary from scripts/build-shim-static.sh.
 *
 * ocaml_shim_host_signal_number : int -> int
 *
 * Converts an OCaml abstract signal code (as reported by
 * Unix.waitpid's WSIGNALED) to the host OS signal number, via the
 * runtime's own conversion table.  The wire trailer must carry real OS
 * signal numbers (9 for SIGKILL, 15 for SIGTERM on Linux/macOS), not
 * OCaml's internal codes.
 */
#include <caml/mlvalues.h>
#include <caml/memory.h>

/* caml_convert_signal_number is exported by the OCaml runtime (the unix
   library's own kill.c calls it), but its declaration (caml/signals.h:99
   on OCaml 5.5) sits inside the CAML_INTERNALS block spanning
   signals.h:56-117, which dune-built stubs do not define — including the
   header alone yields an implicit-declaration error.  Declare the
   prototype locally rather than opting into internals; the 9/15/2
   mapping is pinned by the "host signal numbers" unit test. */
CAMLextern int caml_convert_signal_number(int);

#ifdef __linux__
#include <caml/unixsupport.h>
#include <signal.h>
#include <sys/prctl.h>
#endif

CAMLprim value ocaml_prctl_set_pdeathsig(value vunit)
{
  CAMLparam1(vunit);
#ifdef __linux__
  if (prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0)
    uerror("prctl(PR_SET_PDEATHSIG)", Nothing);
#endif
  CAMLreturn(Val_unit);
}

CAMLprim value ocaml_shim_host_signal_number(value vsig)
{
  CAMLparam1(vsig);
  CAMLreturn(Val_int(caml_convert_signal_number(Int_val(vsig))));
}
