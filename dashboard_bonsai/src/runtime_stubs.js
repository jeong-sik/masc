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
// 6 has no TLS stubs, so the bundle throws on first init:
//   TypeError: runtime.caml_domain_tls_set is not a function
//     at init (domain.ml:578)
//
// Browser bundles are single-threaded, so TLS reduces to a global map
// keyed by the slot identifier. Same shape as the runtime's DLS
// implementation, just under a separate global to keep the namespaces
// independent (in case OxCaml ever uses both for distinct values in
// the same program).

//Provides: caml_domain_tls_set
function caml_domain_tls_set (key, value) {
  globalThis.__caml_tls = globalThis.__caml_tls || Object.create(null);
  globalThis.__caml_tls[key] = value;
  return 0;
}

//Provides: caml_domain_tls_get
function caml_domain_tls_get (key) {
  var tls = globalThis.__caml_tls;
  if (tls && Object.prototype.hasOwnProperty.call(tls, key)) {
    return tls[key];
  }
  return 0;
}
