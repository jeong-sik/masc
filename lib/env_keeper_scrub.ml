(** Keeper subprocess env scrub / pass policy (RFC-0007 PR-1 / #9639 Cluster B).

    Default-deny (allowlist) model: only explicitly permitted env vars cross
    the keeper subprocess boundary. This eliminates the infinite-product-type
    problem of maintaining an exhaustive denylist — new secrets are blocked by
    default. Credentials enter through [Keeper_secret_projection], never an
    ambient-environment escape hatch.

    Keeper GitHub execution must use the selected MASC credential bundle,
    never the operator's ambient GitHub token/config or SSH agent. *)

(** Exact-match allowlist for a local Keeper process. Docker daemon control
    variables are deliberately absent from this boundary. *)
let keeper_allow_exact : string list =
  [
    (* Process basics *)
    "PATH"; "HOME"; "TMPDIR"; "TMP"; "TEMP"
  ; "LANG"; "LC_ALL"; "LC_CTYPE"
  ; "USER"; "LOGNAME"; "SHELL"
  ; "TERM"; "TERMINFO"; "PAGER"; "EDITOR"; "VISUAL"
  ; "XDG_CONFIG_HOME"; "XDG_CACHE_HOME"; "XDG_DATA_HOME"
  ; "OCAMLRUNPARAM"
  ; "OPAMROOT"; "OPAM_SWITCH_PREFIX"

    (* Corporate proxy / certificate — required in restricted network
       environments. Values are not credentials by themselves. *)
  ; "HTTP_PROXY"; "HTTPS_PROXY"; "NO_PROXY"
  ; "SSL_CERT_FILE"

    (* GitHub tokens (GITHUB_TOKEN / GH_TOKEN) are intentionally NOT listed
       here. They end with the [_TOKEN] deny suffix, so even if listed they
       would be denied — the operator's ambient host token must never cross
       into a keeper. The keeper's own GitHub token is supplied out-of-band by
       [Keeper_secret_projection] (Docker [--env-file] / Local overlay), which
       bypasses this allowlist. See RFC-0236 §6 and RFC-0007. *)

    (* Git user identity — not credentials by themselves. *)
  ; "GIT_AUTHOR_NAME"; "GIT_AUTHOR_EMAIL"
  ; "GIT_COMMITTER_NAME"; "GIT_COMMITTER_EMAIL"

    (* MASC operational — these are read by Env_config_core and friends.
       Secrets that happen to share the [MASC_] prefix are blocked by
       [deny_prefixes] below. *)
  ; "MASC_BASE_PATH"; "MASC_BASE_PATH_INPUT"
  ; "MASC_BASE_PATH_RESOLUTION_SOURCE"
  ; "MASC_CONFIG_DIR"; "MASC_MODEL_CATALOG"
  ; "MASC_HOST"; "MASC_HTTP_PORT"; "MASC_HTTP_BASE_URL"; "MASC_URL"
  ; "MASC_ORCHESTRATOR_ENABLED"; "MASC_DISABLE_HITL"
  ; "MASC_LOG_LEVEL"; "MASC_LOG_ROUTINE_LEVEL"
  ; "MASC_TELEMETRY_ENABLED"; "MASC_PARSE_WARN"; "MASC_GOVERNANCE_LEVEL"
  ; "MASC_GIT_FETCH_TIMEOUT_SEC"
  ; "MASC_DATA_DIR"; "MASC_PERSONAS_DIR"
  ]

(** Exact additions used only by the Docker control-plane subprocess. They
    must never enter a local Keeper command environment. *)
let control_plane_allow_exact =
  [ "DOCKER_HOST"; "DOCKER_TLS_VERIFY"; "DOCKER_CERT_PATH"
  ; "MASC_KEEPER_TEST_DOCKER_LOG"
  ]

(** Locale categories are the only open prefix family. Runtime configuration
    families are resolved by the parent process and are not re-exported. *)
let common_allow_prefixes : string list = [ "LC_" ]

(** Prefix denials — even under the [MASC_] family, these carry host-server
    tokens and must never reach a keeper subprocess or container. *)
let deny_prefixes : string list =
  [ "MASC_ADMIN_"; "MASC_INTERNAL_" ]

(** Suffix denials — any key ending with these is treated as a credential
    regardless of prefix. *)
let deny_suffixes : string list =
  [ "_API_KEY"; "_TOKEN"; "_SECRET"; "_PASSWORD"; "_CREDENTIALS" ]

let table_of_keys keys =
  let t = Hashtbl.create (List.length keys) in
  List.iter (fun key -> Hashtbl.replace t key ()) keys;
  t

let keeper_allow_exact_table = table_of_keys keeper_allow_exact
let control_plane_allow_exact_table = table_of_keys control_plane_allow_exact

let is_allowed_common_prefix key =
  List.exists (fun prefix -> String.starts_with ~prefix key) common_allow_prefixes

let is_denied_prefix key =
  List.exists (fun prefix -> String.starts_with ~prefix key) deny_prefixes

let is_denied_suffix key =
  List.exists (fun suffix -> String.ends_with ~suffix key) deny_suffixes

let allowed_by_table table key =
  (Hashtbl.mem table key || is_allowed_common_prefix key)
  && not (is_denied_prefix key || is_denied_suffix key)

let is_keeper_process_allowed key =
  allowed_by_table keeper_allow_exact_table key

let is_control_plane_allowed key =
  (is_keeper_process_allowed key
   || Hashtbl.mem control_plane_allow_exact_table key)
  && not (is_denied_prefix key || is_denied_suffix key)

let key_of_entry entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some i -> String.sub entry 0 i

let is_url_var key = String.equal key "HTTP_PROXY" || String.equal key "HTTPS_PROXY"

let index_substring_from s sub start =
  let slen = String.length sub in
  let len = String.length s in
  let rec scan i =
    if i + slen > len then None else if String.sub s i slen = sub then Some i else scan (i + 1)
  in
  scan start
;;

let index_char_from s start c =
  let len = String.length s in
  let rec scan i = if i >= len then None else if Char.equal s.[i] c then Some i else scan (i + 1) in
  scan start
;;

let scrub_url_value value =
  match index_substring_from value "://" 0 with
  | None -> value
  | Some scheme_end ->
    let auth_start = scheme_end + 3 in
    let auth_end =
      match index_char_from value auth_start '/' with
      | None -> String.length value
      | Some idx -> idx
    in
    if auth_end <= auth_start
    then value
    else (
      match String.index_opt (String.sub value auth_start (auth_end - auth_start)) '@' with
      | None -> value
      | Some at_idx ->
        let host_offset = auth_start + at_idx in
        String.concat
          ""
          [ String.sub value 0 auth_start
          ; "[REDACTED]"
          ; String.sub value host_offset (String.length value - host_offset)
          ])
;;

let scrub_entry entry =
  let key = key_of_entry entry in
  if is_url_var key
  then (
    match String.index_opt entry '=' with
    | None -> entry
    | Some idx ->
      let value = String.sub entry (idx + 1) (String.length entry - idx - 1) in
      let scrubbed = scrub_url_value value in
      if String.equal value scrubbed then entry else key ^ "=" ^ scrubbed)
  else entry
;;

let filter_environment ~is_allowed existing =
  Array.to_list existing
  |> List.filter (fun e -> is_allowed (key_of_entry e))
  |> List.map scrub_entry
  |> Array.of_list

let filter_keeper_environment existing =
  filter_environment ~is_allowed:is_keeper_process_allowed existing

let filter_control_plane_environment existing =
  filter_environment ~is_allowed:is_control_plane_allowed existing

(* Force a deterministic system-message locale on top of the scrubbed
   env. libc's [strerror] is translated by [LC_MESSAGES]; on a non-C host
   locale the EINTR message that keeper matches as a retry marker
   ("interrupted system call", see [Keeper_turn_sandbox_runtime]) would be
   localised and the substring match would silently miss, disabling EINTR
   retry. We pin messages to C and leave character encoding ([LC_CTYPE] /
   [LANG]) to the host so UTF-8 tool output is unaffected. [LC_ALL] has
   higher POSIX precedence than [LC_MESSAGES], so a host [LC_ALL] would
   override our pin; we neutralise it to the empty string, which POSIX
   treats as unset (not as the "C" locale), leaving the remaining
   categories to [LANG] / [LC_CTYPE]. *)
let lc_messages_pin = [ "LC_ALL="; "LC_MESSAGES=C" ]

let filter_control_plane_environment_c_messages existing =
  let scrubbed =
    filter_control_plane_environment existing
    |> Array.to_list
    |> List.filter (fun e ->
      match key_of_entry e with
      | "LC_ALL" | "LC_MESSAGES" -> false
      | _ -> true)
  in
  Array.of_list (scrubbed @ lc_messages_pin)
