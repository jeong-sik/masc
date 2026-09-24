(** Write and Edit for a tree the endpoint owns.

    The host handler ([Keeper_tool_filesystem_runtime]) writes through Eio
    capabilities on a directory it can open; a tree on an OpenSSH host or in
    a guest's work volume is not a directory this host can open. So the
    bytes go where every command of such a keeper already goes: through
    [masc-exec-shim] over the remote lane, as a [sh] payload with the content
    on stdin, at the path {!Keeper_remote_path} translates the keeper's host
    bookkeeping path to.

    What stays the same as the host handler: the path is resolved and jailed
    in the keeper's host namespace first (the same
    [resolve_keeper_confined_write_path]), the same modes, the same patch, the
    same evidence, the same per-path lease. A write in the keeper's own tree is
    internal and takes no Gate decision, as on the host. A path the tree
    refuses may be under one of the endpoint's declared roots; the caller
    decides through [declared_root_writes] whether it is written and which
    Gate decides it, as the host handler decides a write outside the
    playground. There is no publication-recovery journal, because the replace
    is [mktemp] + [mv] on the endpoint's own filesystem.

    Failures are typed by the payload's exit code, which the scripts choose,
    never by reading its stderr. *)

open Keeper_meta_contract
open Keeper_tool_shared_runtime

(* [$0] is the script name, [$1] the translated path. The temporary file is
   made beside the target so [mv] is a rename on one filesystem; a replaced
   file keeps its mode, a new one gets 0644 regardless of umask. A payload
   killed between [mktemp] and [mv] leaves [.masc-write.*] beside the
   target; it is named so a person can tell whose it is. *)
let overwrite_script =
  "set -e; d=$(dirname \"$1\"); mkdir -p \"$d\"; t=$(mktemp \"$d/.masc-write.XXXXXX\"); \
   cat > \"$t\"; if [ -e \"$1\" ]; then chmod \"$(stat -c %a \"$1\")\" \"$t\"; else chmod 0644 \"$t\"; fi; \
   mv -f \"$t\" \"$1\""
;;

let append_script = "set -e; d=$(dirname \"$1\"); mkdir -p \"$d\"; cat >> \"$1\""

(* A path under an endpoint's declared roots (#38593) was judged lexically,
   on this host, before the Gate was asked; the endpoint's filesystem can
   disagree, because a symbolic link under a root may lead outside it. So the
   script that writes checks, on the endpoint and against the directory it
   writes in, that it is physically under one of the roots given after the
   target ([$2]...), each root resolved the same way:
   - the deepest existing ancestor is checked before [mkdir -p], so no
     directory is created through a link;
   - the script then [cd]s into the directory, checks where it is, and names
     the file only as [./name] from there, so every later step acts on the
     directory the check saw;
   - a captured path carries a marker through [$(...)], which would otherwise
     drop a trailing newline from a name, and the target's directory and
     name are split by parameter expansion, which keeps it;
   - a target that is a link or a directory is refused, and [mv -T] never
     moves into a directory that a racing link could put there.
   A refusal exits {!declared_root_escape_exit} with its reason on stderr; no
   declared root, or a directory on the way, that cannot be resolved exits
   {!declared_root_unresolved_exit}. The roots are resolved when the write
   runs, so a root that is itself a link is followed: the operator declared
   it. *)
let declared_root_escape_exit = 6
let declared_root_unresolved_exit = 7

let declared_root_prelude =
  let escape = string_of_int declared_root_escape_exit in
  let unresolved = string_of_int declared_root_unresolved_exit in
  String.concat "\n"
    [ "set -e"
    ; "t=$1; shift"
    ; "phys() { phys_out=$(cd \"$1\" 2>/dev/null && pwd -P && echo .) || return 1; phys_out=${phys_out%??}; }"
    ; "under_root() {"
    ; "  q=$1; shift"
    ; "  for r in \"$@\"; do"
    ; "    phys \"$r\" || continue"
    ; "    case \"$q/\" in \"${phys_out%/}\"/*) return 0;; esac"
    ; "  done"
    ; "  return 1"
    ; "}"
    ; "refuse() { printf '%s\\n' \"$1\" >&2; exit " ^ escape ^ "; }"
    ; "unresolved() { printf '%s\\n' \"$1\" >&2; exit " ^ unresolved ^ "; }"
    ; "any=0; for r in \"$@\"; do if phys \"$r\"; then any=1; fi; done"
    ; "[ \"$any\" = 1 ] || unresolved declared_root_unavailable"
    ; "d=${t%/*}; [ -n \"$d\" ] || d=/; b=${t##*/}"
    ; "a=$d; while [ ! -d \"$a\" ]; do a=${a%/*}; [ -n \"$a\" ] || a=/; done"
    ; "phys \"$a\" || unresolved directory_unavailable"
    ; "under_root \"$phys_out\" \"$@\" || refuse resolves_outside_declared_roots"
    ; "mkdir -p \"$d\""
    ; "cd \"$d\""
    ; "p=$(pwd -P && echo .); p=${p%??}"
    ; "under_root \"$p\" \"$@\" || refuse resolves_outside_declared_roots"
    ; "if [ -L \"./$b\" ]; then refuse target_is_symbolic_link; fi"
    ; "if [ -d \"./$b\" ]; then refuse target_is_directory; fi"
    ]
;;

let declared_root_overwrite_script =
  declared_root_prelude
  ^ "\nw=$(mktemp ./.masc-write.XXXXXX); cat > \"$w\"; \
     if [ -e \"./$b\" ]; then chmod \"$(stat -c %a \"./$b\")\" \"$w\"; else chmod 0644 \"$w\"; fi; \
     mv -f -T \"$w\" \"./$b\""
;;

let declared_root_append_script = declared_root_prelude ^ "\ncat >> \"./$b\""

(* A patch source that is not a regular file exits with this code, chosen
   here, so the handler tells "nothing to patch" from a failed [cat]. *)
let patch_source_missing_exit = 3

let read_source_script =
  Printf.sprintf "if [ -f \"$1\" ]; then cat \"$1\"; else exit %d; fi" patch_source_missing_exit
;;

let script_name = "masc-remote-write"

type content_mode =
  | Replace_whole
  | Append_tail

let write_argv ~mode ~remote_path =
  let script =
    match mode with
    | Replace_whole -> overwrite_script
    | Append_tail -> append_script
  in
  [ "sh"; "-c"; script; script_name; remote_path ]
;;

let declared_root_write_argv ~mode ~endpoint_path ~roots =
  let script =
    match mode with
    | Replace_whole -> declared_root_overwrite_script
    | Append_tail -> declared_root_append_script
  in
  [ "sh"; "-c"; script; script_name; endpoint_path ] @ roots
;;

let read_source_argv ~remote_path = [ "sh"; "-c"; read_source_script; script_name; remote_path ]

let timeout_sec () = Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()

(* The jail root is the keeper's own playground; a confined path under any
   other root cannot be represented on the endpoint. The host handler sends
   such a path to the Gate; here it is refused, because the remote lane has
   no target for it. *)
let confined_is_keeper_playground ~(config : Workspace.config) ~(meta : keeper_meta) confined =
  let normalized path = Keeper_alerting_path.normalize_path_for_check_stripped path in
  String.equal
    (normalized (Keeper_alerting_path.confined_root confined))
    (normalized (Keeper_sandbox.host_root_abs_of_meta ~config meta))
;;

let describe_status = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
;;

let run ~endpoint ~cwd ~argv ~stdin =
  let runner = Keeper_sandbox_remote.runner ~timeout_sec:(timeout_sec ()) endpoint in
  runner ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:(Some stdin)
    ~argv ~env:[||] ~cwd:(Some cwd)
;;

let success_payload ~target ~(meta : keeper_meta) fields : Yojson.Safe.t =
  `Assoc
      ([ "ok", `Bool true; "path", `String target ]
       @ fields
       @ [ "via", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile) ])
;;

type patch_request =
  { old_string : string
  ; new_string : string
  ; replace_all : bool
  }

type authorize_declared_root =
  endpoint:Exec_ssh_endpoint.t
  -> requested_target:string
  -> mode:Keeper_tool_write_mode.t
  -> content_source:Keeper_write_content.t
  -> content:string
  -> patch:patch_request option
  -> Keeper_gate.decision

type declared_root_writes =
  | Refuse_declared_roots
  | Authorize_declared_roots of authorize_declared_root

(* Where a remote write lands. A name in the keeper's tree is internal and
   needs no decision; an endpoint path under a declared root is outside the
   tree, so the caller's Gate decides it the way it decides a host write
   outside the playground. *)
type remote_target =
  | Keeper_tree_target of
      { target : string
      ; remote_path : string
      }
  | Declared_root_target of
      { endpoint_path : string
      ; endpoint_config : Exec_ssh_endpoint.t
      ; authorize : authorize_declared_root
      }

let handle_content_with_endpoint
      ~declared_root_writes
      ~content_source
      ~content
      ~(endpoint : Keeper_sandbox_remote.t)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let content () = match content with Some bytes -> bytes | None -> invalid_arg "Patch has no replacement content" in
  let path = Safe_ops.json_string ~default:"" "path" args in
  let failure ~class_ ~target message =
    Keeper_tool_execution.failure ~class_ (error_json ~fields:[ "path", `String target ] message)
  in
  if String.trim path = ""
  then
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json "path is required. Good: path='lib/foo.ml'. Bad: path=''.")
  else
    match Keeper_tool_write_mode.of_args args with
    | Error mode_raw ->
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (error_json (Keeper_tool_write_mode.rejection_message mode_raw))
    | Ok mode ->
      let confined_endpoint =
        match mode with
        | Keeper_tool_write_mode.Overwrite -> Keeper_alerting_path.Lexical_entry
        | Append | Patch -> Keeper_alerting_path.Follow_referent
      in
      let keeper_tree =
        match
          resolve_keeper_confined_write_path ~config ~meta ~endpoint:confined_endpoint ~raw_path:path
        with
        | Error (refusal : Keeper_alerting_path.path_refusal) ->
          Error
            (Keeper_tool_execution.failure
               ~class_:refusal.failure_class
               (error_json refusal.message))
        | Ok confined ->
          let target = Keeper_alerting_path.confined_host_path confined in
          if not (confined_is_keeper_playground ~config ~meta confined)
          then
            Error
              (failure ~class_:Tool_result.Policy_rejection ~target
                 (Printf.sprintf
                    "remote lane writes stay inside the keeper playground; %s resolves under %s"
                    target
                    (Keeper_alerting_path.confined_root confined)))
          else
            (match
               Keeper_remote_path.host_to_remote
                 ~base_path:config.base_path
                 ~remote_workspace_root:(Keeper_sandbox_remote.workspace_root endpoint)
                 ~keeper:meta.name
                 target
             with
             | Error message -> Error (failure ~class_:Tool_result.Policy_rejection ~target message)
             | Ok remote_path -> Ok (Keeper_tree_target { target; remote_path }))
      in
      (* Only what the keeper's own tree refused may be a path under the
         endpoint's declared roots (#38593), as for Read: a name the tree
         accepts keeps meaning the keeper's own file. *)
      let resolved =
        match keeper_tree, declared_root_writes with
        | (Ok _ as tree_target), _ -> tree_target
        | (Error _ as refused), Refuse_declared_roots -> refused
        | (Error _ as refused), Authorize_declared_roots authorize ->
          (* The endpoint this write runs on is the one whose roots decide it
             and whose configuration the Gate is shown, so the decision cannot
             name one host while the bytes go to another. *)
          (match Keeper_sandbox_remote.transport endpoint with
           | Keeper_sandbox_remote.Openssh { endpoint = endpoint_config; _ } ->
             (match Keeper_sandbox_remote_lane.declared_path_of_endpoint endpoint_config path with
              | Some endpoint_path ->
                Ok (Declared_root_target { endpoint_path; endpoint_config; authorize })
              | None -> refused)
           | Keeper_sandbox_remote.Container_exec _ | Keeper_sandbox_remote.Docker_exec _ ->
             refused)
      in
      (match resolved with
       | Error refused -> refused
       | Ok remote_target ->
         let target, remote_path =
           match remote_target with
           | Keeper_tree_target { target; remote_path } -> target, remote_path
           | Declared_root_target { endpoint_path; _ } -> endpoint_path, endpoint_path
         in
         let keeper_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
         (* [extra_fields] carries the patch operation fields the Edit output
            schema advertises — the endpoint lane emits them from the same
            apply_patch application the evidence comes from, so an
            [/occurrences] reference is answered on both lanes, not only on the
            host one. *)
         let write ~content_mode ~mode_label ~body ~extra_fields ~evidence ~patch =
           let run_write () =
             let argv, declared_roots =
               match remote_target with
               | Keeper_tree_target _ -> write_argv ~mode:content_mode ~remote_path, None
               | Declared_root_target { endpoint_config; _ } ->
                 let roots = endpoint_config.Exec_ssh_endpoint.allowed_paths in
                 ( declared_root_write_argv ~mode:content_mode ~endpoint_path:remote_path ~roots
                 , Some roots )
             in
             let status, _stdout, stderr =
               Masc_exec.Sandbox_target.status_tuple
                 (run ~endpoint ~cwd:keeper_root ~argv ~stdin:body)
             in
             match status, declared_roots with
             | Unix.WEXITED code, Some roots when code = declared_root_escape_exit ->
               failure ~class_:Tool_result.Policy_rejection ~target
                 (Printf.sprintf
                    "path_outside_declared_root: on endpoint %s, %s was refused (%s); the \
                     declared roots are %s. Nothing was written"
                    (Keeper_sandbox_remote.name endpoint)
                    target
                    (String.trim (Exec_policy.truncate_for_log stderr))
                    (String.concat ", " roots))
             | Unix.WEXITED 0, (None | Some _) ->
               Log.Keeper.info
                 "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=%s bytes=%d via=remote"
                 meta.name target mode_label (String.length body);
               let execution =
                 Keeper_tool_execution.success_data
                   (success_payload ~target ~meta
                      ([ "mode", `String mode_label
                       ; "bytes_written", `Int (String.length body)
                       ]
                      @ extra_fields))
               in
               (match evidence with
                | Some evidence -> Keeper_tool_execution.with_file_change_evidence evidence execution
                | None -> execution)
             | status, (None | Some _) ->
               failure ~class_:Tool_result.Runtime_failure ~target
                 (Printf.sprintf
                    "remote write failed (%s) on endpoint %s: %s"
                    (describe_status status)
                    (Keeper_sandbox_remote.name endpoint)
                    (Exec_policy.truncate_for_log stderr))
           in
           match remote_target with
           | Keeper_tree_target _ -> run_write ()
           | Declared_root_target { authorize; endpoint_config; _ } ->
             (match
                authorize
                  ~endpoint:endpoint_config
                  ~requested_target:target
                  ~mode
                  ~content_source
                  ~content:body
                  ~patch
              with
              | Keeper_gate.Allow authorization ->
                Keeper_tool_execution.with_gate_authorization authorization (run_write ())
              | Keeper_gate.Deferred { operation; approval_id; reason; audit_receipts } ->
                Keeper_gate_deferred_payload.create
                  ~operation
                  ~approval_id
                  ~reason
                  ~audit_receipts
                  ~context:(`Assoc [ "path", `String target ])
                  ()
                |> Keeper_gate_deferred_payload.to_execution
              | Keeper_gate.Unavailable reason ->
                Keeper_tool_execution.failure
                  ~class_:Tool_result.Dependency_unavailable
                  (error_json
                     ~fields:
                       [ "path", `String target
                       ; "error", `String "gate_unavailable"
                       ; "gate_reason", `String (Keeper_gate.unavailable_reason_to_string reason)
                       ]
                     (Keeper_tool_filesystem_guidance.text
                        Keeper_tool_filesystem_guidance.Gate_record_unavailable)))
         in
         Keeper_external_resource_lease.with_lease
           (Keeper_external_resource_lease.File_path target)
           (fun () ->
             match mode with
             | Overwrite ->
               write ~content_mode:Replace_whole ~mode_label:"overwrite" ~body:(content ())
                 ~extra_fields:[]
                 ~evidence:(Some (Keeper_file_change_evidence.written (content ())))
                 ~patch:None
             | Append ->
               write ~content_mode:Append_tail ~mode_label:"append" ~body:(content ())
                 ~extra_fields:[] ~evidence:None ~patch:None
             | Patch ->
               let old_string = Safe_ops.json_string ~default:"" "old_string" args in
               let new_string = Safe_ops.json_string ~default:"" "new_string" args in
               let replace_all = Safe_ops.json_bool ~default:false "replace_all" args in
               if old_string = ""
               then
                 Keeper_tool_execution.failure
                   ~class_:Tool_result.Policy_rejection
                   (error_json
                      (Keeper_tool_filesystem_guidance.patch_requires_old_string_text ()))
               else
                 let status, current, stderr =
                   Masc_exec.Sandbox_target.status_tuple
                     (run ~endpoint ~cwd:keeper_root
                        ~argv:(read_source_argv ~remote_path) ~stdin:"")
                 in
                 (match status with
                  | Unix.WEXITED 0 ->
                    (match
                       Keeper_tool_patch.apply_patch ~old_string ~new_string ~replace_all current
                     with
                     | Error message ->
                       failure ~class_:Tool_result.Workflow_rejection ~target message
                     | Ok application when String.equal current application.updated ->
                       Keeper_tool_execution.success_data
                         (success_payload ~target ~meta
                            [ "mode", `String "patch"; "changed", `Bool false
                            ; "occurrences", `Int application.occurrence_count
                            ; "replace_all", `Bool replace_all
                            ; "bytes_written", `Int 0 ])
                     | Ok application ->
                       write ~content_mode:Replace_whole ~mode_label:"patch"
                         ~body:application.updated
                         ~extra_fields:
                           [ "changed", `Bool true
                           ; "occurrences", `Int application.occurrence_count
                           ; "replace_all", `Bool replace_all
                           ]
                         ~evidence:(Some (Keeper_tool_patch.file_change_evidence application))
                         ~patch:(Some { old_string; new_string; replace_all }))
                  | Unix.WEXITED code when code = patch_source_missing_exit ->
                    failure ~class_:Tool_result.Workflow_rejection ~target
                      (Keeper_tool_filesystem_guidance.patch_target_missing_text ())
                  | status ->
                    failure ~class_:Tool_result.Runtime_failure ~target
                      (Printf.sprintf
                         "remote read of the patch source failed (%s) on endpoint %s: %s"
                         (describe_status status)
                         (Keeper_sandbox_remote.name endpoint)
                         (Exec_policy.truncate_for_log stderr)))))
;;

let handle_with_endpoint ~declared_root_writes ~endpoint ~config ~meta ~args =
  match Keeper_write_content.of_args args with
  | Error error -> Keeper_write_content.failure error
  | Ok source ->
    (match Keeper_write_content.bytes ~config source with
     | Error error -> Keeper_write_content.failure error
     | Ok content ->
       handle_content_with_endpoint ~declared_root_writes ~content_source:source ~content
         ~endpoint ~config ~meta ~args)
;;

let handle ~declared_root_writes ~turn_sandbox_factory ~(config : Workspace.config) ~(meta : keeper_meta) ~args =
  let cwd = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  match Keeper_sandbox_remote_lane.endpoint ?turn_sandbox_factory ~config ~meta ~cwd () with
  | Error message ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Dependency_unavailable
      (error_json ~fields:[ "path", `String (Safe_ops.json_string ~default:"" "path" args) ] message)
  | Ok endpoint -> handle_with_endpoint ~declared_root_writes ~endpoint ~config ~meta ~args
;;
