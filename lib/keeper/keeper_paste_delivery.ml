(* See the .mli for the staging-and-delivery contract. *)

type retain_reason =
  | Endpoint_unavailable of string
  | Staging_read_failed of string
  | Remote_write_failed of string

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
;;

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
          | Error detail ->
            Retained
              { file_name
              ; reason = Remote_write_failed detail
              ; content = Some content
              }
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
                   "paste delivery: %s (%d bytes) delivered to the endpoint workspace"
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
