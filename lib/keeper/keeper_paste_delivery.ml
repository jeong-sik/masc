(* See the .mli for the staging-and-delivery contract. The prefix/suffix
   match below selects files; it never branches logic on their contents. *)

let paste_file_prefix = "pasted-"
let paste_file_suffix = ".txt"

let is_staged_paste_name name =
  String.starts_with ~prefix:paste_file_prefix name
  && String.ends_with ~suffix:paste_file_suffix name
;;

let staged_file_names ~staging_dir =
  match Sys.readdir staging_dir with
  | exception Sys_error _ -> []
  | entries ->
    entries
    |> Array.to_list
    |> List.filter (fun name ->
         is_staged_paste_name name
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

type retain_reason =
  | Staging_read_failed of string
  | Remote_write_failed of string

type outcome =
  | Delivered of { file_name : string; bytes : int }
  | Retained of { file_name : string; reason : retain_reason }

let retain_reason_to_string = function
  | Staging_read_failed detail -> Printf.sprintf "staged file unreadable: %s" detail
  | Remote_write_failed detail -> Printf.sprintf "endpoint write failed: %s" detail
;;

let deliver_staged_pastes ~write ~staging_dir =
  List.map
    (fun file_name ->
       let staging_path = Filename.concat staging_dir file_name in
       match read_staged staging_path with
       | Error detail -> Retained { file_name; reason = Staging_read_failed detail }
       | Ok content ->
         (match write ~file_name ~content with
          | Error detail -> Retained { file_name; reason = Remote_write_failed detail }
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
     file, with the handler's own payload as the retained evidence. *)
  match execution.Keeper_tool_execution.disposition with
  | Tool_result.Completed () -> Ok ()
  | Tool_result.Deferred () | Tool_result.Failed _ ->
    Error execution.Keeper_tool_execution.raw_output
;;

let deliver_for_turn ~config ~(meta : Keeper_meta_contract.keeper_meta) ~turn_sandbox_factory =
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Shared_mount -> ()
  | Keeper_types_profile_sandbox.Endpoint_owned ->
    let staging_dir = Keeper_sandbox.host_root_abs_of_meta ~config meta in
    (match staged_file_names ~staging_dir with
     | [] -> ()
     | staged ->
       (match
          Keeper_sandbox_remote_lane.endpoint ?turn_sandbox_factory ~config ~meta ~cwd:staging_dir ()
        with
        | Error message ->
          Log.Keeper.warn
            ~keeper_name:meta.name
            "paste delivery: %d staged paste(s) stay in %s: %s"
            (List.length staged)
            staging_dir
            message
        | Ok endpoint ->
          let outcomes =
            deliver_staged_pastes
              ~write:(write_through_endpoint ~endpoint ~config ~meta)
              ~staging_dir
          in
          List.iter
            (fun outcome ->
               match outcome with
               | Delivered { file_name; bytes } ->
                 Log.Keeper.info
                   ~keeper_name:meta.name
                   "paste delivery: %s (%d bytes) delivered to the endpoint workspace"
                   file_name
                   bytes
               | Retained { file_name; reason } ->
                 Log.Keeper.warn
                   ~keeper_name:meta.name
                   "paste delivery: %s stays staged: %s"
                   file_name
                   (retain_reason_to_string reason))
            outcomes))
;;
