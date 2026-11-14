open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Result.Syntax
open Keeper_tool_read_window
open Keeper_tool_filesystem_guidance
open Keeper_tool_filesystem_runtime_shared

(** Read max_bytes clamp. [read_file_default_max_bytes] is the
    canonical default; [Tool_shard_limits.read_file_default_max_bytes]
    re-exports it at a leaf module so the tool schema in tool_shard.ml
    can reference the same value without creating a dependency cycle. *)
let read_file_default_max_bytes = Tool_shard_limits.read_file_default_max_bytes

let read_file_min_max_bytes = 512
let read_file_max_max_bytes = Tool_shard_limits.read_file_max_max_bytes

(** Read line window. The Read descriptor (agent.read_file) exposes
    [offset]/[limit] as LINE coordinates — the shape mainstream Read tools
    train models on: [offset] is the 1-based first line, [limit] caps
    returned lines. [max_bytes] stays a byte budget on the returned content.
    The descriptor used to translate [limit] straight into [max_bytes], so a
    model asking for 200 lines received max(512, 200) = 512 bytes with
    [truncated=true] and could never read past the file head — live keepers
    re-issued the byte-identical Read for 200+ calls inside a single turn.
    [next_offset] in the payload is what makes forward progress expressible. *)
(* A window that starts at line 1 can only ever return bytes from the first
   [max_bytes] of the file (the response is byte-budgeted), so its fetch stays
   at [max_bytes]; only a window that starts deeper needs to scan further to
   locate its lines. *)
let read_window_fetch_bytes ~max_bytes = function
  | { start_line = 1; max_lines = _ } -> max_bytes
  | _ -> read_file_max_max_bytes
;;

(* Range violations are rejected loudly instead of being defaulted: a model
   that sent [limit=0] or [offset=-3] gets a payload naming the contract, so
   the next attempt can self-correct. *)
let read_line_window_of_args args =
  Keeper_tool_read_window.of_args args
  |> Result.map_error (fun error ->
    let guidance = match error with
      | Below_one { coordinate = Offset; value = offset } -> Offset_not_1_based { offset }
      | Below_one { coordinate = Limit; value = limit } -> Limit_not_positive { limit }
      | Invalid_integer { coordinate; value } -> Invalid_read_integer { coordinate; value }
      | Not_an_object value -> Invalid_read_arguments { value }
    in
    fs_guidance_text guidance)
;;

type read_file_resolution_error = Read_path_error of Keeper_alerting_path.path_refusal

let string_opt_nonempty name json =
  match Safe_ops.json_string_opt name json with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
;;

(* The rejection names the cwds that would have worked.
   A keeper that guesses the host layout ("workspace/<org>/<repo>") gets the
   same "directory does not exist" as one that asked for a repo nobody
   materialized, and the two need opposite responses: retry with the right
   path, or stop asking. A live Keeper hit the first and kept retrying
   (#23442). The set is measured, not prescribed: whatever git checkouts sit
   under the keeper's workspace root, wherever the keeper put them. An empty
   set is reported as empty rather than omitted, because "no repository is
   materialized" is the answer to a different question than "you named the
   wrong one" — and by the same argument a scan that failed is a third answer
   and says so. *)
let available_cwd_hint ~config ~meta =
  let root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  match Keeper_playground_checkouts.discover ~root with
  | Ok (Keeper_playground_checkouts.Complete []) ->
    " no repository is materialized for this keeper yet, so the workspace root \
     is the only cwd that exists"
  | Ok (Keeper_playground_checkouts.Complete checkouts) ->
    Printf.sprintf
      " available cwds: %s"
      (String.concat
         ", "
         (List.map
            (fun (c : Keeper_playground_checkouts.checkout) -> c.relative_path)
            checkouts))
  | Ok (Keeper_playground_checkouts.Partial { found; limit }) ->
    (* Presenting a truncated list as complete is worse than saying it is
       truncated: a keeper that cannot find its repo in a list that looks
       exhaustive concludes it should stop asking. *)
    " "
    ^ fs_guidance_text
        (Available_cwds_partial
           { limit = Keeper_playground_checkouts.limit_to_string limit
           ; cwds =
               String.concat
                 ", "
                 (List.map
                    (fun (c : Keeper_playground_checkouts.checkout) -> c.relative_path)
                    found)
           })
  | Error error ->
    " "
    ^ fs_guidance_text
        (Checkout_scan_failed
           { detail = Keeper_playground_checkouts.scan_error_to_string error })
;;

let resolve_read_file_cwd ~(config : Workspace.config) ~(meta : keeper_meta) ~cwd =
  match cwd with
  | None -> Ok (Keeper_sandbox.host_root_abs_of_meta ~config meta)
  | Some raw_cwd ->
    (* The same resolver names the cwd of Read, Grep and Execute:
       [Keeper_tool_shared_runtime.host_path_of_keeper_visible_path]. *)
    let* cwd = resolve_keeper_read_path ~config ~meta ~raw_path:raw_cwd in
    let cwd_refusal reason = Error (Keeper_alerting_path.caller_refusal reason) in
    (* The hint scans the host playground, so it is only offered where the
       host holds the tree. *)
    (match cwd_existence ~meta cwd with
     | Endpoint_decides | Host_directory -> Ok cwd
     | Host_file ->
       cwd_refusal (Keeper_alerting_path.Cwd_is_file { cwd })
     | Host_missing ->
       cwd_refusal
         (Keeper_alerting_path.Missing_cwd
            { cwd; read_hint = Some (available_cwd_hint ~config ~meta) }))
;;

(* What a Read names. A remote keeper's file is either a name in its own
   bookkeeping tree, which the lane translates to the endpoint, or an endpoint
   path under one of the endpoint's declared roots ([allowed_paths], #38593),
   which is already the endpoint's own name. *)
type read_file_target =
  | Keeper_tree_file of string
  | Declared_endpoint_file of string

let read_file_target_path = function
  | Keeper_tree_file path | Declared_endpoint_file path -> path
;;

(* The host containment check guards a name in the keeper's bookkeeping tree.
   A declared endpoint path is no host name at all: the endpoint account is its
   boundary, as it is for the Execute command that may name the same path. *)
let check_read_file_target ~config ~meta = function
  | Keeper_tree_file target -> Keeper_sandbox_containment.check_read_target ~config ~meta ~target
  | Declared_endpoint_file _ -> Ok ()
;;

let resolve_read_file_target
      ?endpoint_error
      ~read_authority
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~(raw_path : string)
      ()
  =
  let args, raw_path = match read_authority with
    | None -> args, raw_path
    | Some authority ->
      let remote_workspace_root = Keeper_sandbox_remote_lane.read_authority_workspace_root authority in
      ( Keeper_workspace_namespace.project_file_args ~remote_workspace_root ~config ~meta args
      , Keeper_workspace_namespace.project_input ~remote_workspace_root ~config ~meta raw_path ) in
  let cwd = string_opt_nonempty "cwd" args in
  let raw_path = String.trim raw_path in
  if raw_path = ""
  then
    Error
      (Read_path_error
         (Keeper_alerting_path.refusal_of_rejection Keeper_alerting_path.Path_required))
  else (
    let keeper_tree =
      let* cwd_abs = resolve_read_file_cwd ~config ~meta ~cwd in
      resolve_keeper_read_path_in_cwd ~config ~meta ~host_cwd:cwd_abs ~raw_path
    in
    match keeper_tree with
    | Ok path -> Ok (Keeper_tree_file path)
    | Error refusal ->
      (* Only what the keeper's own tree refused may be a path under the
         endpoint's declared roots (#38593). Everything the tree accepts keeps
         the meaning it had, however a declared root is spelled. *)
      (match
         (match read_authority with
          | None -> Keeper_sandbox_remote_lane.declared_endpoint_path_of_args ~config ~meta ~path:raw_path ~cwd
          | Some authority ->
            Keeper_sandbox_remote_lane.with_read_authority_endpoint authority ~config ~meta
              (fun _ -> Ok (Keeper_sandbox_remote_lane.read_authority_declared_path_of_args authority ~path:raw_path ~cwd)))
       with
       | Ok (Some endpoint_path) -> Ok (Declared_endpoint_file endpoint_path)
       | Ok None ->
         (match endpoint_error with
          | Some endpoint_error ->
            Error
              (Read_path_error
                 (Keeper_alerting_path.endpoint_unresolved ~tree_refusal:refusal ~endpoint_error))
          | None -> Error (Read_path_error refusal))
       | Error resolution_error ->
         let endpoint_error = Option.value endpoint_error ~default:resolution_error in
         Error
           (Read_path_error
              (Keeper_alerting_path.endpoint_unresolved ~tree_refusal:refusal ~endpoint_error))))
;;

(* A Read that did not return content says whose it is to fix: a path, limit
   or file the caller named is a [Policy_rejection]; a backend or host I/O
   failure is a [Runtime_failure]. *)
type read_file_attempt =
  | Read_succeeded of Yojson.Safe.t
  | Read_refused of
      { failure_class : Tool_result.tool_failure_class
      ; payload : string
      }

let read_authority_for_call ~config ~(meta : keeper_meta) read_authority =
  match read_authority, meta.sandbox_profile with
  | Some _, _ | None, (Docker | Micro_vm) -> Ok read_authority
  | None, Remote_ssh -> Keeper_sandbox_remote_lane.capture_read_authority ~config ~meta ()
;;

let read_sandbox_raw_prefix ?read_authority ?turn_sandbox_factory ~config ~meta ~path ?cwd ~max_bytes () =
  let args = `Assoc (match cwd with None -> [] | Some cwd -> [ "cwd", `String cwd ]) in
  let* read_authority =
    match read_authority_for_call ~config ~meta read_authority with
    | Ok _ as authority -> authority
    | Error detail ->
      (match resolve_read_file_target ~endpoint_error:detail ~read_authority:None ~config ~meta ~args ~raw_path:path () with
       | Error (Read_path_error refusal) ->
         Error (Keeper_sandbox_read_backend.Read_refused refusal.Keeper_alerting_path.message)
       | Ok _ -> Error (Keeper_sandbox_read_backend.Read_failed detail))
  in
  let* read_target =
    resolve_read_file_target ~read_authority ~config ~meta ~args ~raw_path:path ()
    |> Result.map_error (fun (Read_path_error refusal) ->
           Keeper_sandbox_read_backend.Read_refused refusal.Keeper_alerting_path.message)
  in
  let* () =
    check_read_file_target ~config ~meta read_target
    |> Result.map_error (fun (refusal : Keeper_alerting_path.path_refusal) ->
           Keeper_sandbox_read_backend.Read_refused refusal.message)
  in
  Keeper_sandbox_read_backend.read_raw_prefix ?read_authority ?turn_sandbox_factory ~config ~meta
    ~host_path:(read_file_target_path read_target) ~max_bytes
    ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Read ()) ()
;;

let prepared_read_confined ~config ~(meta : Keeper_meta_contract.keeper_meta) ~args ~target =
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  | Endpoint_owned -> Ok None
  | Shared_mount ->
    let root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
    if not (Keeper_alerting_path.is_within_root_norm
              ~root_norm:(Keeper_alerting_path.normalize_path_for_check_stripped root) target)
    then Ok None
    else
      let* _ = read_line_window_of_args args in
      Keeper_alerting_path.resolve_keeper_confined_path ~config ~sandbox_roots:[root]
        ~endpoint:Keeper_alerting_path.Follow_referent ~raw_path:target
      |> Result.map Option.some
      |> Result.map_error (fun rejection ->
        (Keeper_alerting_path.refusal_of_rejection rejection).message)
;;

let prepare_read ~sw ~config ~meta ~args =
  let path = Safe_ops.json_string ~default:"" "path" args in
  let* target = resolve_read_file_target ~read_authority:None ~config ~meta ~args ~raw_path:path ()
    |> Result.map_error (fun (Read_path_error refusal) -> refusal.message) in
  let* () = check_read_file_target ~config ~meta target
    |> Result.map_error (fun (refusal : Keeper_alerting_path.path_refusal) -> refusal.message) in
  let* confined = prepared_read_confined ~config ~meta ~args ~target:(read_file_target_path target) in
  match confined with
  | None -> Ok None
  | Some confined ->
    Keeper_prepared_file.prepare ~sw ~operation:Read ~config ~meta ~args ~confined
;;

let prepared_read_scopes = Keeper_prepared_file.scopes
let release_prepared_read = Keeper_prepared_file.release

let read_prepared_window ~config ~meta ~args ~target ~window ~max_bytes prepared =
  let* confined = prepared_read_confined ~config ~meta ~args ~target in
  match confined with
  | None -> Error "prepared Read no longer belongs to the Keeper's shared-mount tree"
  | Some confined ->
    Keeper_prepared_file.with_parents ~operation:Read ~config ~meta ~args ~confined prepared
      (fun ~parent_dir:_ ~parent_components:_ ~leaf:_ ~source_parent_dir ~source_leaf ->
        Eio.Switch.run @@ fun sw ->
        let file = Eio.Path.open_in ~sw Eio.Path.(source_parent_dir / source_leaf) in
        if (Eio.File.stat file).kind <> `Regular_file then Error "prepared Read source is not a regular file"
        else
          let reader = Eio.Buf_read.of_flow ~max_size:read_file_max_max_bytes file in
          let rec skip_lines remaining =
            if remaining > 0 then begin
              Eio.Buf_read.skip_while (fun c -> c <> '\n') reader;
              match Eio.Buf_read.peek_char reader with
              | None -> ()
              | Some _ -> Eio.Buf_read.char '\n' reader; skip_lines (remaining - 1)
            end
          in
          skip_lines (window.Keeper_tool_read_window.start_line - 1);
          let output = Buffer.create (min max_bytes (Eio.Buf_read.buffered_bytes reader)) in
          let rec take remaining =
            if remaining > 0 then
              match Eio.Buf_read.peek_char reader with
              | None -> ()
              | Some _ ->
                let count = min remaining (Eio.Buf_read.buffered_bytes reader) in
                Buffer.add_string output (Cstruct.to_string ~len:count (Eio.Buf_read.peek reader));
                Eio.Buf_read.consume reader count;
                take (remaining - count)
          in
          take max_bytes;
          Ok (Buffer.contents output))
;;

let handle_read_file_with_preparation
      ~read_authority
      ~prepared_read
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  match read_authority_for_call ~config ~meta read_authority with
  | Error detail -> Keeper_tool_execution.failure
      ~class_:Tool_result.Dependency_unavailable (error_json detail)
  | Ok read_authority ->
  let path = Safe_ops.json_string ~default:"" "path" args in
  let max_bytes =
    Safe_ops.json_int ~default:read_file_default_max_bytes "max_bytes" args
    |> fun n -> max read_file_min_max_bytes (min read_file_max_max_bytes n)
  in
  let cwd = string_opt_nonempty "cwd" args in
  let read_target =
    let* window = read_line_window_of_args args |> Result.map_error (fun e -> `Window e) in
    let* target = resolve_read_file_target ~read_authority ~config ~meta ~args ~raw_path:path ()
      |> Result.map_error (fun (Read_path_error refusal) -> `Path refusal) in
    Ok (window, target)
  in
  match read_target with
  | Error (`Window window_error) ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json window_error)
  | Error (`Path refusal) ->
    Keeper_tool_execution.failure
      ~class_:refusal.Keeper_alerting_path.failure_class
      (error_json refusal.message)
  | Ok (window, read_target) ->
    let target = read_file_target_path read_target in
    let visible_target = match read_authority, meta.sandbox_profile with
      | Some authority, Remote_ssh ->
        Keeper_sandbox_read_backend.container_path_of_host_with_authority
          ~read_authority:authority ~config ~meta ~host_path:target
      | Some _, (Docker | Micro_vm) | None, _ -> Ok target in
    (match visible_target with
     | Error detail -> Keeper_tool_execution.failure
         ~class_:Tool_result.Dependency_unavailable (error_json detail)
     | Ok visible_target ->
    let payload_of_slice ~scan_complete body =
      match
        slice_read_window ~window ~first_line:window.start_line ~max_bytes ~scan_complete body
      with
      (* The backend body begins at [window.start_line], so the window's first
         line is the body's first line and always has a start. Only
         [handle_owned_read_file_with_outcome] can get [Offset_beyond_scan], in
         its own arm; #38609 removes the [Error] case there. Reaching it here is
         masc's defect, not the caller's. *)
      | Error `Offset_beyond_scan ->
        Read_refused
          { failure_class = Tool_result.Runtime_failure
          ; payload =
              error_json
                ~fields:
                  [ "path", `String target
                  ; "offset", `Int window.start_line
                  ]
                (fs_guidance_text
                   (Offset_beyond_window
                      { offset = window.start_line
                      ; window_bytes = String.length body
                      }))
          }
      | Ok slice ->
        let optional_fields =
          List.concat
            [ (match slice.next_offset with
               | Some next -> [ "next_offset", `Int next ]
               | None -> [])
            ; (if slice.last_line_partial
               then [ "last_line_partial", `Bool true ]
               else [])
            ]
        in
        Read_succeeded
          (`Assoc
              ([ "ok", `Bool true
               ; "path", `String visible_target
               ; "bytes", `Int (String.length slice.window_content)
               ; "truncated", `Bool slice.window_truncated
               ; "offset", `Int window.start_line
               ; "returned_lines", `Int slice.returned_lines
               ; "content", `String slice.window_content
               ]
               @ optional_fields
               @ [ "via", `String (match prepared_read with
                    | None -> Keeper_sandbox_read_runner.backend_via ~meta
                    | Some _ -> "owned_capability") ]))
    in
    let refused failure_class message =
      Read_refused
        { failure_class
        ; payload = error_json ~fields:[ "path", `String target ] message
        }
    in
    let missing_file error =
      Read_refused
        { failure_class = Tool_result.Policy_rejection
        ; payload = missing_file_error_json ~cwd ~raw_path:(Some path) ~target ~error
        }
    in
    let run_read () =
      (* RFC-0006 Phase B-1: Docker keepers are always contained to their
         playground bundle on the host before any read-side I/O proceeds.
         The resolver-level sandbox_roots check is augmented by this
         strict containment so host FS cannot leak through Read
         while Execute is container-isolated. *)
      match check_read_file_target ~config ~meta read_target with
      | Error (refusal : Keeper_alerting_path.path_refusal) ->
        refused refusal.failure_class refusal.message
      | Ok () ->
        (match prepared_read with
         | Some prepared ->
           (match read_prepared_window ~config ~meta ~args ~target ~window ~max_bytes prepared with
            | Ok body -> payload_of_slice ~scan_complete:(String.length body < max_bytes) body
            | Error detail -> refused Tool_result.Policy_rejection detail)
         | None ->
        (* Unprepared reads retain the sandbox backend and its mount
           restrictions. Prepared shared-mount reads above instead retain
           capabilities confined to this Keeper's own physical tree. *)
        (* Default-cwd initialization belongs to ordinary execution, rather
           than resolution that a resource preparation may also perform. *)
        if Option.is_none cwd then
          ignore (Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta);
        let timeout_sec = Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Read () in
        (* The backend streams from [window.start_line], so the byte bound is
           the window's and every line of the file is reachable. *)
        let read_file = match read_authority with
          | None -> Keeper_sandbox_read_runner.read_file
          | Some authority -> Keeper_sandbox_read_backend.read_file ~read_authority:authority in
        (match
           read_file
             ?turn_sandbox_factory
             ~start_line:window.start_line
             ~config
             ~meta
             ~host_path:target
             ~max_bytes
             ~timeout_sec
             ()
         with
         | Error (Keeper_sandbox_read_backend.Missing_file error) -> missing_file error
         | Error (Keeper_sandbox_read_backend.Not_a_file detail) ->
           refused Tool_result.Policy_rejection detail
         | Error (Keeper_sandbox_read_backend.Read_refused detail) ->
           refused Tool_result.Policy_rejection detail
         | Error (Keeper_sandbox_read_backend.Read_failed detail) ->
           refused Tool_result.Runtime_failure detail
         | Ok body ->
           payload_of_slice ~scan_complete:(String.length body < max_bytes) body))
    in
    (match run_read () with
     | Read_succeeded json -> Keeper_tool_execution.success_data json
     | Read_refused { failure_class; payload } ->
       Keeper_tool_execution.failure ~class_:failure_class payload))
;;

let handle_read_file_with_outcome ~turn_sandbox_factory ~config ~meta ~args =
  handle_read_file_with_preparation ~read_authority:None ~prepared_read:None ~turn_sandbox_factory ~config ~meta ~args
;;

let handle_read_file_with_authority ~read_authority ~turn_sandbox_factory ~config ~meta ~args =
  handle_read_file_with_preparation ~read_authority:(Some read_authority)
    ~prepared_read:None ~turn_sandbox_factory ~config ~meta ~args
;;

let handle_prepared_read_file_with_outcome ~prepared_read ~config ~meta ~args =
  match handle_read_file_with_preparation ~read_authority:None ~prepared_read:(Some prepared_read)
      ~turn_sandbox_factory:None ~config ~meta ~args with
  | result -> result
  | exception (Eio.Io _ as error) ->
    Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure
      (error_json (Printexc.to_string error))
;;
