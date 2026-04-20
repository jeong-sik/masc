// js_of_ocaml runtime stubs for OxCaml-only primitives.
//
// OxCaml 5.2.0+ox introduces Sys.arch_amd64 / Sys.arch_arm64 unboxed
// primitives referenced by the basement library. Stock js_of_ocaml 6
// runtime does not define these, and basement raises
//   Failure "Cannot determine architecture: must be amd64 or arm64"
// when both return 0 — so we must report exactly one as true.
//
// Detect via navigator.userAgent: M-series Macs report the host arch in
// the UA string. Default to arm64 when unknown — most modern dev/prod
// targets (Apple Silicon, AWS Graviton) are arm64, and Bonsai is a
// browser bundle so the value only feeds runtime branches that are
// always JS-emulated anyway. The choice is cosmetic; what matters is
// that exactly one of the two reports true.

//Provides: caml_sys_const_arch_amd64 const
function caml_sys_const_arch_amd64 () {
  if (typeof navigator !== 'undefined' && navigator.userAgent) {
    return /Intel|x86_64|amd64|x64|Win64|WOW64/i.test(navigator.userAgent) ? 1 : 0;
  }
  return 0;
}

//Provides: caml_sys_const_arch_arm64 const
function caml_sys_const_arch_arm64 () {
  if (typeof navigator !== 'undefined' && navigator.userAgent) {
    return /Intel|x86_64|amd64|x64|Win64|WOW64/i.test(navigator.userAgent) ? 0 : 1;
  }
  return 1;
}

// OxCaml extends OCaml 5's Domain Local Storage (DLS, already in jsoo
// runtime) with Thread Local Storage (TLS) primitives. Stock js_of_ocaml
// 6 has no TLS stubs.
//
// Shape matters: jsoo's DLS get/set take/return the *entire* OCaml array
// as a single argument (see runtime: caml_domain_dls_set(a){caml_domain_dls = a;}).
// OxCaml's TLS uses the same convention — basement calls Array.blit on
// the value returned by tls_get, so it must be an OCaml array, not a
// dict keyed by slot ids. An earlier dict-based stub (#8816) crashed
// with Invalid_argument("Array.blit") for exactly this reason.
//
// Browser bundles are single-threaded, so TLS reduces to one global
// array. [0] is the OCaml empty-array tag — basement initialises real
// values via blit on first use.

//Provides: caml_domain_tls_set
function caml_domain_tls_set (a) {
  globalThis.__caml_tls_storage = a;
  return 0;
}

//Provides: caml_domain_tls_get
function caml_domain_tls_get (_unit) {
  return globalThis.__caml_tls_storage || [0];
}
