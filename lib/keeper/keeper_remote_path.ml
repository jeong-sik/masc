(** Bidirectional path translation for the remote execution lane.

    [host_root_abs_of_meta] call-site classification (Task 7 audit):

    - Logical-path only, unchanged: [keeper_sandbox_repo_path],
      [keeper_turn_helpers], [keeper_agent_run], [keeper_sandbox] location
      bundles, and [keeper_tool_shared_runtime] input resolution. These values
      describe the keeper-visible bookkeeping namespace; they do not perform
      remote I/O.
    - Remote-proxied: [keeper_tool_execute_runtime],
      [keeper_sandbox_read_backend], [keeper_workspace_read_ops], and
      [keeper_tool_filesystem_runtime]. Commands and structured reads translate
      through this module before reaching the shim.
    - Docker-only, explicitly divergent: [keeper_sandbox_docker],
      [keeper_sandbox_docker_container_name], [keeper_sandbox_factory], and
      [keeper_turn_sandbox_runtime]. Their host roots are bind-mount inputs and
      are never used by the remote lane.
    - Host control/telemetry, explicitly divergent: [keeper_sandbox_control].
      It reports and manages the local bookkeeping bundle; endpoint readiness
      and remote lifecycle belong to the preflight/bootstrap layer.

    Every current call site belongs to one of those categories. New remote I/O
    must use this module instead of adding another prefix rewrite.

    The caller supplies the already resolved remote workspace root. This
    module maps only between that endpoint namespace and the Keeper's host
    bookkeeping namespace; it does not infer a workspace layout. *)

let normalize_host path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes
;;

(* Remote-namespace strings must never be resolved against the host
   filesystem: realpath substitutes host symlinks and macOS firmlinks into
   them (on macOS, /home/x resolves to /System/Volumes/Data/home/x), and the
   substituted path is what the shim then fails to find on the endpoint. The
   endpoint owns real resolution — its cwd jail runs realpath there — so the
   host side only cleans dot segments lexically. *)
let normalize_remote path =
  Masc_exec.Path_scope.lexical_normalize_abs path
  |> Keeper_alerting_path.strip_trailing_slashes
;;

(* Keeper-relative logical path: same lexical discipline, without
   absolutizing. Leading [..] segments survive so escape detection below
   still sees them. *)
let normalize_logical path =
  Masc_exec.Path_scope.lexical_normalize_relative path
;;

let safe_keeper keeper = Playground_paths.sanitize_keeper_name keeper

let host_root ~base_path ~keeper =
  Filename.concat base_path (Playground_paths.bundle_root (safe_keeper keeper))
  |> normalize_host
;;

let at_or_below ~root path =
  String.equal root path
  || String.starts_with ~prefix:(root ^ Filename.dir_sep) path
;;

let suffix_below ~root path =
  if String.equal root path
  then ""
  else
    String.sub path (String.length root + 1)
      (String.length path - String.length root - 1)
;;

type lane =
  | Ssh_endpoint
  | Microvm_guest

type breach =
  | Relative_escape
  | Outside_keeper_root

type jail_refusal =
  { lane : lane
  ; breach : breach
  ; path : string
  ; host_root : string
  ; endpoint_root : string
  }

let ssh_jail_code = "remote_ssh_path_jail_violation"
let microvm_jail_code = "microvm_remote_path_jail_violation"

(* The SSH wording names the host bookkeeping root, as it did before the
   refusal was typed. A microVM Keeper sees only its guest, so its refusal
   names the guest root it can use. *)
let jail_refusal_to_string { lane; breach; path; host_root; endpoint_root } =
  match lane, breach with
  | Ssh_endpoint, Relative_escape ->
    Printf.sprintf "%s: keeper-relative path %s escapes %s" ssh_jail_code path host_root
  | Ssh_endpoint, Outside_keeper_root ->
    Printf.sprintf "%s: %s is outside keeper playground %s" ssh_jail_code path host_root
  | Microvm_guest, Relative_escape ->
    Printf.sprintf "%s: keeper-relative path %s escapes the Keeper's guest root %s"
      microvm_jail_code path endpoint_root
  | Microvm_guest, Outside_keeper_root ->
    Printf.sprintf "%s: %s is outside the Keeper's guest root %s"
      microvm_jail_code path endpoint_root
;;

let host_to_remote ~lane ~base_path ~remote_workspace_root ~keeper path =
  let hroot = host_root ~base_path ~keeper in
  let rroot = normalize_remote remote_workspace_root in
  let refuse breach =
    Error { lane; breach; path; host_root = hroot; endpoint_root = rroot }
  in
  if Filename.is_relative path
  then
    let logical = normalize_logical path in
    if String.equal logical ""
    then Ok rroot
    else if String.equal logical ".."
            || String.starts_with ~prefix:(".." ^ Filename.dir_sep) logical
    then refuse Relative_escape
    else Ok (Filename.concat rroot logical)
  else
    let remote_candidate = normalize_remote path in
    if at_or_below ~root:rroot remote_candidate
    then Ok remote_candidate
    else
      (* Not endpoint-namespace: read it as a host bookkeeping path, where
         resolving against the host filesystem is the correct comparison. *)
      let host_candidate = normalize_host path in
      if at_or_below ~root:hroot host_candidate
      then
        let suffix = suffix_below ~root:hroot host_candidate in
        if String.equal suffix "" then Ok rroot else Ok (Filename.concat rroot suffix)
      else refuse Outside_keeper_root
;;

let remote_to_logical ~remote_workspace_root path =
  let rroot = normalize_remote remote_workspace_root in
  let normalized = normalize_remote path in
  if String.equal normalized rroot
  then "."
  else if at_or_below ~root:rroot normalized
  then suffix_below ~root:rroot normalized
  else path
;;

let endpoint_to_host ~base_path ~remote_workspace_root ~keeper path =
  if Filename.is_relative path then None
  else
    let root = normalize_remote remote_workspace_root in
    let path = normalize_remote path in
    if at_or_below ~root path then
      let suffix = suffix_below ~root path in
      let host = host_root ~base_path ~keeper in
      Some (if String.equal suffix "" then host else Filename.concat host suffix)
    else None
;;
