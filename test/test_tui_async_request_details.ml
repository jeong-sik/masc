(** Actual durable request -> exact status projection -> typed TUI read ownership.
    No renderer, layout, wording, snapshot or PTY assertions. Unexecuted here. *)
open Alcotest
open Masc_tui_types
module Async = Masc.Keeper_msg_async
module Detail = Masc.Tui_decode_async_request
let () = Mirage_crypto_rng_unix.use_default ()
let value = function Ok value -> value | Error detail -> fail detail
let rec remove path = match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> ()
let with_base f =
  let path=Filename.temp_file "tui-original-async-" "" in
  Unix.unlink path;Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove path) (fun () -> f path)
let observed state target = match Masc_tui_fetched.view_for ~equal:Detail.equal_target state.tools_async_detail ~key:target with
  | Ready (Detail.Observed snapshot) | Stale (Detail.Observed snapshot,_) -> snapshot
  | Absent | Loading | Failed _ | Ready Detail.Absent | Stale (Detail.Absent,_) -> fail "original physical observation absent"
let begin_read state ~force = begin_tools_async_detail state ~force |> Option.get

let scenario ok () = with_base @@ fun base_path -> Eio_main.run @@ fun _env -> Eio.Switch.run @@ fun sw ->
  let entered,resolve_entered=Eio.Promise.create () and release,resolve_release=Eio.Promise.create () in
  let terminal,resolve_terminal=Eio.Promise.create () in
  let effect_path=Filename.concat base_path "original-effect" in
  let request_id = match Async.submit ~base_path ~background_sw:sw ~caller:"original-submitter"
      ~keeper_name:"different-target" ~on_worker_settled:(fun outcome -> Eio.Promise.resolve resolve_terminal outcome)
      ~f:(fun _ ->
        let channel=open_out_bin effect_path in output_string channel "original resource mutation\n";close_out channel;
        Eio.Promise.resolve resolve_entered ();Eio.Promise.await release;
        if ok then Masc.Keeper_types_profile.tool_result_ok "original result"
        else Masc.Keeper_types_profile.tool_result_error ~class_:Tool_result.Runtime_failure "original failure") () with
    | Ok {acceptance=Async.Durably_accepted;request_id} -> request_id
    | Ok _ | Error _ -> fail "original request not durably admitted" in
  Eio.Promise.await entered;
  let target : Detail.target={submitted_by="original-submitter";keeper_name="different-target";request_id} in
  let wire () = Masc.Server_async_request_observability.project_request ~base_path
      ~submitted_by:target.submitted_by ~request_id in
  let read () = Detail.decode ~target (wire ()) in
  let state=create_state ~workspace:"fixture" ~local_base_path:base_path ~port:0 ~refresh_interval:0. () in
  state.view <- Tools;state.tools_pane <- Tools_async;
  state.tools_async_observation <- Some (Masc.Server_async_request_observability.project ~base_path
    |> Masc.Tui_decode.decode_async_request_observation |> value);
  sync_tools_async_selection state;
  check bool "selection keeps original submitter and different target" true
    (Option.equal Detail.equal_target (Some target) state.tools_async_selection);
  state.tools_async_detail_open <- true;
  let old=begin_read state ~force:false in
  suspend_workspace_readings state;
  let current=begin_read state ~force:false in
  complete_tools_async_detail state old (read ());
  check bool "retired read cannot settle the new source" true (Masc_tui_fetched.in_flight state.tools_async_detail);
  complete_tools_async_detail state current (read ());
  check bool "physical worker remains running after status reads" true ((observed state target).phase=Detail.Running);
  let refresh=begin_read state ~force:true in
  complete_tools_async_detail state refresh (Error "original source unavailable");
  check bool "failed refresh keeps original physical observation" true
    (match Masc_tui_fetched.view_for ~equal:Detail.equal_target state.tools_async_detail ~key:target with
     | Stale (Detail.Observed snapshot,_) -> snapshot.phase=Detail.Running
     | _ -> false);
  let retry=begin_read state ~force:true in
  let unavailable = match wire () with
    | `Assoc envelope -> `Assoc (List.map (fun (key,value) -> key, if key="request" then
        (match value with `Assoc fields -> `Assoc (List.map (fun (key,value) ->
          key,if key="continuation" then `Assoc ["kind",`String "unavailable";"detail",`String "logical authority unavailable"] else value) fields)
         | _ -> fail "physical request envelope absent") else value) envelope)
    | _ -> fail "status envelope absent" in
  complete_tools_async_detail state retry (Detail.decode ~target unavailable);
  check bool "logical failure retains an independently read physical worker" true
    ((observed state target).phase=Detail.Running && match (observed state target).logical with
      | Detail.Unavailable _ -> true | Confirmed _ -> false);
  check bool "last confirmed logical source is retained separately" true
    (match state.tools_async_last_logical with Some (_,Detail.Not_composition) -> true | _ -> false);
  Eio.Promise.resolve resolve_release ();ignore (Eio.Promise.await terminal);
  state.tools_async_observation <- Some (Masc.Server_async_request_observability.project ~base_path
    |> Masc.Tui_decode.decode_async_request_observation |> value);
  sync_tools_async_selection state;
  check bool "retired active row cannot replace an open original target" true
    (Option.equal Detail.equal_target (Some target) state.tools_async_selection && state.tools_async_detail_open);
  let final=begin_read state ~force:true in complete_tools_async_detail state final (read ());
  check bool "terminal outcome retains its actual success or failure" true ((observed state target).phase=Detail.Done ok);
  let late=begin_read state ~force:true in
  withdraw_tools_async_details state;
  state.tools_async_selection <- Some target;state.tools_async_detail_open <- true;
  let replacement=begin_read state ~force:false in
  complete_tools_async_detail state late (read ());
  check bool "cleared source cannot borrow a same-ID replacement" true
    (Masc_tui_fetched.in_flight state.tools_async_detail && state.tools_async_last_logical=None);
  complete_tools_async_detail state replacement (read ());
  let wrong={target with submitted_by=target.keeper_name} in
  check bool "target Keeper cannot substitute for original submitter" true (Result.is_error (Detail.decode ~target:wrong (wire ())));
  let channel=open_in_bin effect_path in
  let bytes=really_input_string channel (in_channel_length channel) in close_in channel;
  check string "reads preserve the original effect resource" "original resource mutation\n" bytes

let () = run "original async request details"
  ["resource and read ownership",[test_case "physical success" `Quick (scenario true);
    test_case "physical failure" `Quick (scenario false)]]
