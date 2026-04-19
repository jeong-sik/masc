// js_of_ocaml runtime stubs for OxCaml-only primitives.
//
// OxCaml 5.2.0+ox introduces Sys.arch_amd64 / Sys.arch_arm64 unboxed primitives
// referenced by the basement library. Stock js_of_ocaml 6 runtime does not
// define these. We return 0 (false) for both because the bundle runs in a
// browser, not on a native CPU.

//Provides: caml_sys_const_arch_amd64 const
function caml_sys_const_arch_amd64 () { return 0; }

//Provides: caml_sys_const_arch_arm64 const
function caml_sys_const_arch_arm64 () { return 0; }
