(* See the .mli for the staging-and-delivery contract. *)

type retain_reason =
  | Endpoint_unavailable of string
  | Staging_read_failed of string
  | Remote_write_failed of string
  | Readback_mismatch of string

type retained_paste =
  { file_name : string
  ; reason : retain_reason
  ; content : string option
  }

type outcome =
  | Delivered of { file_name : string; bytes : int }
  | Retained of retained_paste

let retain_reason_to_string = function
  | Endpoint_unavailable detail ->
    Printf.sprintf "endpoint unavailable: %s" detail
  | Staging_read_failed detail ->
    Printf.sprintf "staged file unreadable: %s" detail
  | Remote_write_failed detail ->
    Printf.sprintf "endpoint write failed: %s" detail
  | Readback_mismatch detail ->
    Printf.sprintf "endpoint write reported success but read-back disagreed: %s" detail
;;

(** Basenames of the regular files sitting directly under [staging_dir] that
    parse as spilled-paste names ([Keeper_paste_naming]), sorted. A missing
    or unreadable staging directory means nothing was ever staged, not an
    error. *)
let staged_file_names ~staging_dir =
  match Sys.readdir staging_dir with
  | exception Sys_error _ -> []
  | entries ->
    entries
    |> Array.to_list
    |> List.filter (fun name ->
         Keeper_paste_naming.is_paste_file name
         &&
         match Sys.is_directory (Filename.concat staging_dir name) with
         | true -> false
         | false -> true
         | exception Sys_error _ -> false)
    |> List.sort String.compare
;;

let read_staged path =
  match open_in_bin path with
  | exception Sys_error detail -> Error detail
  | channel ->
    (match
       Fun.protect
         ~finally:(fun () -> close_in_noerr channel)
         (fun () -> really_input_string channel (in_channel_length channel))
     with
     | content -> Ok content
     | exception Sys_error detail -> Error detail)
;;

let deliver_staged_pastes ~write ~staging_dir =
  List.map
    (fun file_name ->
       let staging_path = Filename.concat staging_dir file_name in
       match read_staged staging_path with
       | Error detail ->
         Retained
           { file_name; reason = Staging_read_failed detail; content = None }
       | Ok content ->
         (match write ~file_name ~content with
          | Error reason ->
            Retained { file_name; reason; content = Some content }
          | Ok () ->
            (match Sys.remove staging_path with
             | () -> Delivered { file_name; bytes = String.length content }
             | exception Sys_error detail ->
               (* The bytes are on the endpoint; only the staged copy stayed.
                  The next turn delivers it again, and the delivery write is
                  a whole-file replace, so a repeat is idempotent. *)
               Log.Keeper.warn
                 "paste delivery: staged copy %s could not be removed after delivery (%s); the next turn will deliver it again"
                 file_name
                 detail;
               Delivered { file_name; bytes = String.length content })))
    (staged_file_names ~staging_dir)
;;

(* A write that exits 0 proves the payload ran, not that the bytes are
   readable at the translated path -- 2026-09-04 (#33010): a delivery logged
   "delivered" on a guest serving a stale tree, and the keeper never saw the
   file. So a delivery is verified before it is called delivered: the same
   lane reads the file back at the same translated path and the byte count
   is compared. A count, not a full compare -- a multi-MB paste's bytes stay
   on the endpoint. The observed failure class -- absent file, wrong tree,
   truncated to zero -- all fails this check. [$0] is the script name, [$1]
   the translated path. *)
let readback_script = "wc -c < \"$1\""
let readback_name = "masc-paste-readback"

let readback_argv ~remote_path =
  [ "sh"; "-c"; readback_script; readback_name; remote_path ]
;;

let describe_status = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
;;

(* [host_to_remote] on the bare name is the same translation the write just
   made: the write resolves the name against the keeper's host playground
   and translates that, which is what passing the keeper-relative name here
   computes directly. *)
let verify_readback ~endpoint ~config ~meta ~file_name ~expected_bytes =
  match
    Keeper_remote_path.host_to_remote
      ~base_path:config.Workspace.base_path
      ~remote_root:(Keeper_sandbox_remote.remote_root endpoint)
      ~keeper:meta.Keeper_meta_contract.name
      file_name
  with
  | Error message -> Error message
  | Ok remote_path ->
    let runner =
      Keeper_sandbox_remote.runner
        ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ())
        endpoint
    in
    let cwd = Keeper_sandbox.host_root_abs_of_meta ~config meta in
    let status, stdout, stderr =
      Masc_exec.Sandbox_target.status_tuple
        (runner
           ~on_stdout_chunk:None
           ~on_stderr_chunk:None
           ~stdin_content:None
           ~argv:(readback_argv ~remote_path)
           ~env:[||]
           ~cwd:(Some cwd))
    in
    (match status with
     | Unix.WEXITED 0 ->
       (match int_of_string_opt (String.trim stdout) with
        | Some actual when actual = expected_bytes -> Ok ()
        | Some actual ->
          Error
            (Printf.sprintf
               "%s holds %d bytes after the write, expected %d"
               remote_path
               actual
               expected_bytes)
        | None ->
          let answer = String.trim stdout in
          let answer =
            if String.length answer > 80
            then String.sub answer 0 80 ^ "..."
            else answer
          in
          Error
            (Printf.sprintf
               "read-back of %s answered %S, not a byte count"
               remote_path
               answer))
     | status ->
       Error
         (Printf.sprintf
            "read-back of %s failed (%s) on endpoint %s: %s"
            remote_path
            (describe_status status)
            (Keeper_sandbox_remote.name endpoint)
            (Exec_policy.truncate_for_log stderr)))
;;

let write_through_endpoint ~endpoint ~config ~meta ~file_name ~content =
  let execution =
    Keeper_tool_filesystem_remote_write.handle_with_endpoint
      ~endpoint
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "path", `String file_name
           ; "content", `String content
           ; ( "mode"
             , `String (Keeper_tool_write_mode.to_string Keeper_tool_write_mode.Overwrite) )
           ])
  in
  (* The write handler answers Completed or Failed; Deferred is typed but
     never produced by it. Either non-Completed disposition keeps the staged
     file, with the handler's own payload as the retained evidence. A
     Completed write is still not "delivered": only a read-back through the
     same endpoint that finds the same byte count at the translated path is. *)
  match execution.Keeper_tool_execution.disposition with
  | Tool_result.Completed () ->
    (match
       verify_readback ~endpoint ~config ~meta ~file_name
         ~expected_bytes:(String.length content)
     with
     | Ok () -> Ok ()
     | Error detail -> Error (Readback_mismatch detail))
  | Tool_result.Deferred () | Tool_result.Failed _ ->
    Error (Remote_write_failed execution.Keeper_tool_execution.raw_output)
;;

let log_retained ~keeper_name (retained : retained_paste) =
  Log.Keeper.emit
    Log.Warn
    ~keeper_name
    ~category:Log.Tool
    ~details:
      (`Assoc
         [ "error_kind", `String "keeper_paste_delivery_retained"
         ; "file", `String retained.file_name
         ; "reason", `String (retain_reason_to_string retained.reason)
         ])
    "A staged paste could not be delivered to the keeper workspace"
;;

let content_of_staged ~staging_dir file_name =
  match read_staged (Filename.concat staging_dir file_name) with
  | Ok content -> Some content
  | Error _ -> None
;;

let deliver_for_turn ~config ~(meta : Keeper_meta_contract.keeper_meta) ~turn_sandbox_factory =
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Shared_mount -> []
  | Keeper_types_profile_sandbox.Endpoint_owned ->
    let staging_dir = Keeper_sandbox.host_root_abs_of_meta ~config meta in
    (match staged_file_names ~staging_dir with
     | [] -> []
     | staged ->
       (match
          Keeper_sandbox_remote_lane.endpoint ?turn_sandbox_factory ~config ~meta ~cwd:staging_dir ()
        with
        | Error message ->
          let retained =
            List.map
              (fun file_name ->
                 { file_name
                 ; reason = Endpoint_unavailable message
                 ; content = content_of_staged ~staging_dir file_name
                 })
              staged
          in
          List.iter (log_retained ~keeper_name:meta.name) retained;
          retained
        | Ok endpoint ->
          let outcomes =
            deliver_staged_pastes
              ~write:(write_through_endpoint ~endpoint ~config ~meta)
              ~staging_dir
          in
          List.filter_map
            (fun outcome ->
               match outcome with
               | Delivered { file_name; bytes } ->
                 Log.Keeper.info
                   ~keeper_name:meta.name
                   "paste delivery: %s (%d bytes) delivered and verified on the endpoint workspace"
                   file_name
                   bytes;
                 None
               | Retained retained ->
                 log_retained ~keeper_name:meta.name retained;
                 Some retained)
            outcomes))
;;

let correction_of_retained (retained : retained_paste) =
  match retained.content with
  | Some content ->
    Printf.sprintf
      "[Paste delivery correction: the note above says %s is in your working directory. It is not -- %s. The pasted text follows in full:\n\n%s]"
      retained.file_name
      (retain_reason_to_string retained.reason)
      content
  | None ->
    Printf.sprintf
      "[Paste delivery correction: %s could not be placed in your workspace (%s), and its staged copy could not be read back. Ask the operator to paste the text again.]"
      retained.file_name
      (retain_reason_to_string retained.reason)
;;

let inlined_correction = function
  | [] -> None
  | retained -> Some (String.concat "\n\n" (List.map correction_of_retained retained))
;;
