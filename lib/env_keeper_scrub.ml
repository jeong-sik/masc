(** Host-to-Keeper subprocess environment boundary.

    Only the exact process/runtime keys below are inherited from the host.
    Every tool/provider credential and any additional environment material
    comes from [Keeper_secret_projection], the explicit workspace SSOT.  This
    module therefore needs no product names, credential-name guesses, prefix
    inference, or environment-variable escape hatch. *)

(** Exact-match allowlist — env vars that are known-safe and required for
    keeper / docker CLI / tool execution. *)
let allow_exact : string list =
  [
    (* Process basics *)
    "PATH"; "HOME"; "TMPDIR"; "TMP"; "TEMP"
  ; "LANG"; "LC_ALL"; "LC_CTYPE"
  ; "USER"; "LOGNAME"; "SHELL"
  ; "TERM"; "TERMINFO"; "PAGER"; "EDITOR"; "VISUAL"
  ; "XDG_CONFIG_HOME"; "XDG_CACHE_HOME"; "XDG_DATA_HOME"
  ; "OCAMLRUNPARAM"
  ; "OPAMROOT"; "OPAM_SWITCH_PREFIX"

    (* Docker CLI remote daemon connectivity *)
  ; "DOCKER_HOST"; "DOCKER_TLS_VERIFY"; "DOCKER_CERT_PATH"

    (* Corporate proxy / certificate — required in restricted network
       environments. Values are not credentials by themselves. *)
  ; "HTTP_PROXY"; "HTTPS_PROXY"; "NO_PROXY"
  ; "SSL_CERT_FILE"

    (* MASC operational — these are read by Env_config_core and friends.
       This is an exact list; arbitrary [MASC_*] keys are not inherited. *)
  ; "MASC_BASE_PATH"; "MASC_BASE_PATH_INPUT"
  ; "MASC_BASE_PATH_RESOLUTION_SOURCE"
  ; "MASC_CONFIG_DIR"; "MASC_MODEL_CATALOG"
  ; "MASC_HOST"; "MASC_HTTP_PORT"; "MASC_HTTP_BASE_URL"; "MASC_URL"
  ; "MASC_ORCHESTRATOR_ENABLED"
  ; "MASC_LOG_LEVEL"; "MASC_LOG_ROUTINE_LEVEL"
  ; "MASC_TELEMETRY_ENABLED"; "MASC_PARSE_WARN"
  ; "MASC_DATA_DIR"; "MASC_PERSONAS_DIR"
  ; "MASC_SECRET_DIR"
  ; "MASC_TEST_FAKE_DOCKER_PATH"
  ]

let allow_exact_table =
  let t = Hashtbl.create (List.length allow_exact) in
  List.iter (fun k -> Hashtbl.replace t k ()) allow_exact;
  t

let is_allowed key = Hashtbl.mem allow_exact_table key

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

let filter_environment existing =
  Array.to_list existing
  |> List.filter (fun e -> is_allowed (key_of_entry e))
  |> List.map scrub_entry
  |> Array.of_list
