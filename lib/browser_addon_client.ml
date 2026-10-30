module W = Browser_addon_wire
type error = Unavailable of string | Outcome_unknown of string
type t = {socket_path:string;incarnation:string;max_message_bytes:int;
  control_timeout_sec:float;available:unit -> bool;mutable revoked:bool;mutable poll_state:string option;
  mutable snapshot_token:unit ref option;mutable live_transports:(Browser_lane.client_id * Browser_lane.live_transport) list option}
let create ~socket_path ~incarnation ~max_message_bytes ~control_timeout_sec ~available =
  match Browser_lane.client_id_of_string incarnation with
  | Error message -> Error message
  | Ok _ ->
    if not (Float.is_finite control_timeout_sec) || control_timeout_sec<=0.
      || Filename.is_relative socket_path || max_message_bytes<=0 || max_message_bytes>=Sys.max_string_length then
      Error "invalid private browser endpoint" else
    Ok {socket_path;incarnation;max_message_bytes;control_timeout_sec;available;revoked=false;poll_state=None;snapshot_token=None;live_transports=None}
let revoke t = t.revoked <- true; t.snapshot_token <- None; t.live_transports <- None
let notice_poll_state t ~state_id =
  let changed=t.poll_state<>Some state_id in
  t.poll_state<-Some state_id;changed
let expected command reply = match command,reply with
  | _,W.Service_refusal _ | W.Snapshot,W.Snapshot_result _
  | W.Poll _,W.Poll_result _ | (W.Deliver _|W.Disconnect _|W.Retire|W.Upload_stage _|W.Upload_discard _|W.Download_commit _|W.Download_release _),W.Receipt
  | W.Issue _,W.Issue_result _ -> true
  | (W.Model_requests|Model_result _|Model_wait _),W.Model_reply _ -> true
  | W.Download_claim _,W.Download_reply _ -> true
  | W.Extension _,W.Extension_reply _ -> true
  | (W.Snapshot|Retire|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _|Model_requests|Model_result _|Model_wait _|Extension _|Poll _|Deliver _|Disconnect _|Issue _),
    (W.Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _) -> false
let issue_policy t route verb =
  let open Browser_lane in
  match route with
  | Automation_route | Stagehand_route -> Ok (reply_policy verb)
  | Live_route selected ->
    match reply_policy verb with
    | Executor_owned -> Ok Executor_owned
    | Reply_window ->
      match ego_reply_policy verb with
      | Reply_window -> Ok Reply_window
      | Executor_owned ->
        let transport=Option.bind selected (fun id ->
          Option.bind t.live_transports (List.assoc_opt id)) in
        match transport with
        | Some Ego_task_space -> Ok Executor_owned
        | Some (Web_extension | Webdriver_bidi) -> Ok Reply_window
        | None -> Error (Unavailable "live browser transport is not observed; read this worker's snapshot before dispatch")
let raw_exchange t ~settlement ~admit ~on_cancel_after_dispatch command =
  let available () = settlement || (not t.revoked && t.available ()) in
  if not (available () && admit ()) then Error (Unavailable "browser worker is unavailable")
  else match Eio_context.get_net_opt (),Eio_context.get_clock_opt () with
  | None,_ | _,None -> Error (Unavailable "browser worker network context is unavailable")
  | Some net,Some clock ->
    let text = Yojson.Safe.to_string (W.to_json {W.incarnation=t.incarnation;command}) in
    if String.length text>t.max_message_bytes then Error (Unavailable "browser request exceeds installation transport bound")
    else
      let writing = ref false in
      let allowance=t.control_timeout_sec +. (match command with
        | W.Issue {timeout_sec;_} -> timeout_sec | W.Poll {window_sec;_} -> window_sec
        | W.Snapshot|Retire|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _|Model_requests|Model_result _|Model_wait _|Extension _|Deliver _|Disconnect _ -> 0.) in
      let policy=match command with
        | W.Issue {route;verb;_} -> issue_policy t route verb
        | Snapshot|Retire|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _
        | Model_requests|Model_result _|Model_wait _|Extension _|Poll _|Deliver _|Disconnect _ -> Ok Browser_lane.Reply_window in
      match policy with
      | Error error -> Error error
      | Ok policy ->
      let exchange () = Eio.Switch.run (fun sw ->
        let flow = Eio.Net.connect ~sw net (`Unix t.socket_path) in
        if not (admit () && available ()) then Error (Unavailable "browser worker was retired before dispatch")
        else (
          writing := true;
          Eio.Flow.copy_string (text ^ "\n") flow;
          let reader = Eio.Buf_read.of_flow flow ~initial_size:(min 4096 (t.max_message_bytes+1))
            ~max_size:(t.max_message_bytes+1) in
          let raw = Eio.Buf_read.line reader in
          if String.length raw>t.max_message_bytes then Error (Outcome_unknown "browser reply exceeds installation transport bound")
          else match W.reply_of_json (Yojson.Safe.from_string raw) with
          | Ok reply when expected command reply -> Ok reply
          | Ok _ -> Error (Outcome_unknown "unexpected browser service reply")
          | Error _ -> Error (Outcome_unknown "invalid browser service reply"))) in
      try (match command with
        | W.Retire | W.Model_wait _ | W.Extension _ -> exchange ()
        | W.Issue {route;verb;timeout_sec;_} ->
          let owned_startup=match route with
            | Browser_lane.Stagehand_route -> Option.is_none (Browser_lane.stagehand_server_deadline verb ~timeout_sec)
            | Browser_lane.Automation_route | Browser_lane.Live_route _ -> false in
          (* Policy was fixed before dispatch from the original worker's
             validated metadata, never from a caller-supplied transport. *)
          let executor_owned = match policy with
            | Executor_owned -> true | Reply_window -> false in
          if owned_startup || executor_owned || Browser_lane.verb_uses_model verb then exchange ()
          else Eio.Time.with_timeout_exn clock allowance exchange
        | Snapshot|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _|Model_requests|Model_result _|Poll _|Deliver _|Disconnect _ -> Eio.Time.with_timeout_exn clock allowance exchange)
      with
      | Eio.Cancel.Cancelled _ as cancelled ->
        if !writing then Eio.Cancel.protect on_cancel_after_dispatch;
        raise cancelled
      | (Eio.Io _|Eio.Time.Timeout|End_of_file|Eio.Buf_read.Buffer_limit_exceeded|Yojson.Json_error _) as exn ->
        let detail=match exn with Yojson.Json_error _ -> "malformed browser service reply"
          | Eio.Io _|Eio.Time.Timeout|End_of_file|Eio.Buf_read.Buffer_limit_exceeded -> "browser service transport interrupted"
          | _ -> "browser service transport failed" in
        Error (if !writing then Outcome_unknown detail else Unavailable detail)

let exchange t ~settlement ~admit ~on_cancel_after_dispatch command =
  let snapshot_token=match command with
   | W.Snapshot ->
     let token=ref () in
     t.snapshot_token <- Some token; t.live_transports <- None; Some token
   | Retire|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _
   | Model_requests|Model_result _|Model_wait _|Extension _|Poll _|Deliver _|Disconnect _|Issue _ -> None in
  let result=raw_exchange t ~settlement ~admit ~on_cancel_after_dispatch command in
  match command with
  | W.Snapshot ->
    (match result with
     | Ok (W.Snapshot_result value) ->
       (match Result.bind (Lane_addon_action.canonical value) Browser_addon_observation.decode_snapshot with
        | Ok published ->
          let current=match snapshot_token,t.snapshot_token with
            | Some requested,Some current -> requested==current
            | None,(None|Some _) | Some _,None -> false in
          if current && not t.revoked then
            t.live_transports <- Some (List.map (fun (client:Browser_lane.client_info) -> client.client_id,client.transport) published.clients);
          result
        | Error detail -> Error (Outcome_unknown ("invalid browser transport snapshot: " ^ detail)))
     | Ok (Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _|Service_refusal _)
     | Error _ -> result)
  | Retire|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _
  | Model_requests|Model_result _|Model_wait _|Extension _|Poll _|Deliver _|Disconnect _|Issue _ -> result

let call t ~on_cancel_after_dispatch command =
  exchange t ~settlement:false ~admit:(fun () -> true) ~on_cancel_after_dispatch command
let call_companion t ~admit ~on_cancel_after_dispatch command =
  try exchange t ~settlement:false ~admit ~on_cancel_after_dispatch (W.Extension command) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ -> Error (Outcome_unknown "private browser call outcome unknown")

let transfer_download t ~id ~actor ~route ~verb ~publish =
  let call ~settlement command =
    exchange t ~settlement ~admit:(fun () -> true) ~on_cancel_after_dispatch:(fun () -> ()) command
    |> Result.map_error (function Unavailable detail|Outcome_unknown detail -> detail) in
  let receipt = function
    | W.Receipt -> Ok ()
    | W.Service_refusal {message;_} -> Error message
    | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Issue_result _ ->
        Error "unexpected download settlement receipt" in
  let ( let* )=Result.bind in
  let released=ref None in
  let release ()=Eio.Cancel.protect (fun () ->
    released:=Some (let* reply=call ~settlement:true (W.Download_release {id;actor;route;verb}) in receipt reply)) in
  let transferred=Fun.protect ~finally:release (fun () ->
    let* reply=call ~settlement:false (W.Download_claim {id;actor;route;verb}) in
    let* artifact=match reply with
      | W.Download_reply (Browser_addon_downloads.Published value) -> Ok value
      | Download_reply (Snapshot descriptor) -> publish descriptor
      | Service_refusal {message;_} -> Error message
      | Snapshot_result _|Model_reply _|Extension_reply _|Poll_result _|Receipt|Issue_result _ ->
          Error "unexpected download claim receipt" in
    let* reply=call ~settlement:true (W.Download_commit {id;actor;route;verb;receipt=artifact}) in
    let* ()=receipt reply in Ok artifact) in
  match transferred,!released with
  | Ok artifact,Some (Ok ()) -> Ok artifact
  | Error detail,(Some (Ok ())|None) -> Error detail
  | (Ok _),Some (Error detail) -> Error ("download release unconfirmed: " ^ detail)
  | Error detail,Some (Error release) -> Error (detail ^ "; download release unconfirmed: " ^ release)
  | Ok _,None -> Error "download release did not settle"
