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

let message_of_exn = function
  | Failure msg -> msg
  | exn -> Printexc.to_string exn

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > haystack_len then false
  else
    let rec loop idx =
      if idx + needle_len > haystack_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0

let classify_error (exn : exn) : t =
  let msg = message_of_exn exn in
  let lc = String.lowercase_ascii msg in
  if String.length lc = 0 then Internal "(empty exception)"
  else if contains_substring lc "registry" && contains_substring lc "not found" then
    Registry_lookup msg
  else if contains_substring lc "sandbox_profile" || contains_substring lc "effective_sandbox" then
    Sandbox_profile_resolution msg
  else if contains_substring lc "docker image" && contains_substring lc "not configured" then
    Runtime_image_missing msg
  else if contains_substring lc "runtime" && contains_substring lc "create" then
    Runtime_creation msg
  else if contains_substring lc "normalize" || contains_substring lc "normalize_path" then
    Cwd_normalization msg
  else if contains_substring lc "profile_independent_cwd" then
    Cwd_projection msg
  else if contains_substring lc "cleanup" || contains_substring lc "teardown" then
    Cache_cleanup msg
  else Internal msg
