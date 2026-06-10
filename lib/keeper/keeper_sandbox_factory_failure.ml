(** Failure classification for {!Keeper_sandbox_factory}. *)

type t =
  | Registry_lookup of string
  | Sandbox_profile_resolution of string
  | Runtime_image_missing of string
  | Runtime_creation of string
  | Cwd_normalization of string
  | Cwd_projection of string
  | Cache_cleanup of string
  | Internal of string

let to_string = function
  | Registry_lookup msg -> "registry_lookup:" ^ msg
  | Sandbox_profile_resolution msg -> "sandbox_profile_resolution:" ^ msg
  | Runtime_image_missing msg -> "runtime_image_missing:" ^ msg
  | Runtime_creation msg -> "runtime_creation:" ^ msg
  | Cwd_normalization msg -> "cwd_normalization:" ^ msg
  | Cwd_projection msg -> "cwd_projection:" ^ msg
  | Cache_cleanup msg -> "cache_cleanup:" ^ msg
  | Internal msg -> "internal:" ^ msg

let classify_error (exn : exn) : t =
  let msg = Printexc.to_string exn in
  let lc = String.lowercase_ascii msg in
  if String.length lc = 0 then Internal "(empty exception)"
  else if String.contains lc "registry" && String.contains lc "not found" then
    Registry_lookup msg
  else if String.contains lc "sandbox_profile" || String.contains lc "effective_sandbox" then
    Sandbox_profile_resolution msg
  else if String.contains lc "docker image" && String.contains lc "not configured" then
    Runtime_image_missing msg
  else if String.contains lc "runtime" && String.contains lc "create" then
    Runtime_creation msg
  else if String.contains lc "normalize" || String.contains lc "normalize_path" then
    Cwd_normalization msg
  else if String.contains lc "profile_independent_cwd" then
    Cwd_projection msg
  else if String.contains lc "cleanup" || String.contains lc "teardown" then
    Cache_cleanup msg
  else Internal msg