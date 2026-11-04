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
  ; "MASC_BASE_PATH"
  ; "MASC_BASE_PATH_RESOLUTION_SOURCE"
  ; "MASC_CONFIG_DIR"
  ; "MASC_HOST"; "MASC_HTTP_PORT"; "MASC_HTTP_BASE_URL"; "MASC_URL"
  ; "MASC_LOG_LEVEL"; "MASC_LOG_ROUTINE_LEVEL"
  ; "MASC_TELEMETRY_ENABLED"; "MASC_PARSE_WARN"
  ; "MASC_SECRET_DIR"
  ; "MASC_TEST_FAKE_DOCKER_PATH"
  ; "MASC_KEEPER_TEST_DOCKER_LOG"
  ]

module String_set = Set_util.StringSet

let allow_exact_table = String_set.of_list allow_exact

let is_allowed key = String_set.mem key allow_exact_table

let key_of_entry entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some i -> String.sub entry 0 i

let is_url_var key = String.equal key "HTTP_PROXY" || String.equal key "HTTPS_PROXY"

let scrub_entry entry =
  let key = key_of_entry entry in
  if is_url_var key
  then (
    match String.index_opt entry '=' with
    | None -> entry
    | Some idx ->
      let value = String.sub entry (idx + 1) (String.length entry - idx - 1) in
      let scrubbed = Url_userinfo.redact value in
      if String.equal value scrubbed then entry else key ^ "=" ^ scrubbed)
  else entry
;;

(* A keeper subprocess has no terminal and nobody to answer a prompt, so a
   command that opens an editor or asks for a credential waits for someone who
   is never coming. Measured over 2026-08 on the reference workspace: 23 git
   commands that open an editor held 3.6 hours, the longest a single
   [git rebase --continue] for 2h29m that then reported success. The host
   EDITOR is inherited on purpose (it is on the allowlist above), so git
   launched the operator's own editor into a process with no tty.

   [GIT_EDITOR] is first in git's editor precedence, ahead of core.editor,
   VISUAL and EDITOR, so one key settles all of them and the allowlist stays
   as it is — a tool that reads $EDITOR to show a name still sees one. [false]
   rather than [true]: git stops and says which command needed an editor,
   where [true] would quietly commit a message nobody wrote.

   [GIT_TERMINAL_PROMPT=0] is the same fact for credentials. It is a smaller
   share of the measured time (6 calls, 13 minutes) and is here because the
   prompt has no possible answer in this process either, not because the
   minutes matter. *)
let non_interactive_entries : string list =
  [ "GIT_EDITOR=false"; "GIT_TERMINAL_PROMPT=0" ]

let filter_environment existing =
  (Array.to_list existing
   |> List.filter (fun e -> is_allowed (key_of_entry e))
   |> List.map scrub_entry)
  @ non_interactive_entries
  |> Array.of_list
