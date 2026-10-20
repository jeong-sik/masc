module W = Browser_addon_wire
type error = Unavailable of string | Outcome_unknown of string
type t = {socket_path:string;incarnation:string;max_message_bytes:int;
  control_timeout_sec:float;available:unit -> bool;mutable revoked:bool;mutable poll_state:string option}
let create ~socket_path ~incarnation ~max_message_bytes ~control_timeout_sec ~available =
  match Browser_lane.client_id_of_string incarnation with
  | Error message -> Error message
  | Ok _ ->
    if not (Float.is_finite control_timeout_sec) || control_timeout_sec<=0.
      || Filename.is_relative socket_path || max_message_bytes<=0 || max_message_bytes>=Sys.max_string_length then
      Error "invalid private browser endpoint" else
    Ok {socket_path;incarnation;max_message_bytes;control_timeout_sec;available;revoked=false;poll_state=None}
let revoke t = t.revoked <- true
let notice_poll_state t ~state_id =
  let changed=t.poll_state<>Some state_id in
  t.poll_state<-Some state_id;changed
let expected command reply = match command,reply with
  | _,W.Service_refusal _ | W.Snapshot,W.Snapshot_result _
  | W.Poll _,W.Poll_result _ | (W.Deliver _|W.Disconnect _|W.Retire|W.Upload_stage _|W.Upload_discard _|W.Download_commit _|W.Download_release _),W.Receipt
  | W.Issue _,W.Issue_result _ -> true
  | (W.Model_requests|Model_result _|Model_wait _),W.Model_reply _ -> true
  | W.Download_claim _,W.Download_reply _ -> true
  | (W.Snapshot|Retire|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _|Model_requests|Model_result _|Model_wait _|Poll _|Deliver _|Disconnect _|Issue _),
    (W.Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _) -> false
let exchange t ~settlement ~on_cancel_after_dispatch command =
  let available () = settlement || (not t.revoked && t.available ()) in
  if not (available ()) then Error (Unavailable "browser worker is unavailable")
  else match Eio_context.get_net_opt (),Eio_context.get_clock_opt () with
  | None,_ | _,None -> Error (Unavailable "browser worker network context is unavailable")
  | Some net,Some clock ->
    let text = Yojson.Safe.to_string (W.to_json {W.incarnation=t.incarnation;command}) in
    if String.length text>t.max_message_bytes then Error (Unavailable "browser request exceeds installation transport bound")
    else
      let writing = ref false in
      let allowance=t.control_timeout_sec +. (match command with
        | W.Issue {timeout_sec;_} -> timeout_sec | W.Poll {window_sec;_} -> window_sec
        | W.Snapshot|Retire|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _|Model_requests|Model_result _|Model_wait _|Deliver _|Disconnect _ -> 0.) in
      let exchange () = Eio.Switch.run (fun sw ->
        let flow = Eio.Net.connect ~sw net (`Unix t.socket_path) in
        if not (available ()) then Error (Unavailable "browser worker was retired before dispatch")
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
          | Error detail -> Error (Outcome_unknown ("invalid browser service reply: " ^ detail)))) in
      try (match command with
        | W.Retire | W.Model_wait _ -> exchange ()
        | W.Issue {route;verb;timeout_sec;_} ->
          let owned_startup=match route with
            | Browser_lane.Stagehand_route -> Option.is_none (Browser_lane.stagehand_server_deadline verb ~timeout_sec)
            | Browser_lane.Automation_route | Browser_lane.Live_route _ -> false in
          if owned_startup || Browser_lane.verb_uses_model verb then exchange ()
          else Eio.Time.with_timeout_exn clock allowance exchange
        | Snapshot|Upload_stage _|Upload_discard _|Download_claim _|Download_commit _|Download_release _|Model_requests|Model_result _|Poll _|Deliver _|Disconnect _ -> Eio.Time.with_timeout_exn clock allowance exchange)
      with
      | Eio.Cancel.Cancelled _ as cancelled ->
        if !writing then Eio.Cancel.protect on_cancel_after_dispatch;
        raise cancelled
      | (Eio.Io _|Eio.Time.Timeout|End_of_file|Eio.Buf_read.Buffer_limit_exceeded|Yojson.Json_error _) as exn ->
        let detail=Printexc.to_string exn in
        Error (if !writing then Outcome_unknown detail else Unavailable detail)

let call t ~on_cancel_after_dispatch command =
  exchange t ~settlement:false ~on_cancel_after_dispatch command

let transfer_download t ~id ~actor ~route ~verb ~publish =
  let call ~settlement command =
    exchange t ~settlement ~on_cancel_after_dispatch:(fun () -> ()) command
    |> Result.map_error (function Unavailable detail|Outcome_unknown detail -> detail) in
  let receipt = function
    | W.Receipt -> Ok ()
    | W.Service_refusal {message;_} -> Error message
    | Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Issue_result _ ->
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
      | Snapshot_result _|Model_reply _|Poll_result _|Receipt|Issue_result _ ->
          Error "unexpected download claim receipt" in
    let* reply=call ~settlement:true (W.Download_commit {id;actor;route;verb;receipt=artifact}) in
    let* ()=receipt reply in Ok artifact) in
  match transferred,!released with
  | Ok artifact,Some (Ok ()) -> Ok artifact
  | Error detail,(Some (Ok ())|None) -> Error detail
  | (Ok _),Some (Error detail) -> Error ("download release unconfirmed: " ^ detail)
  | Error detail,Some (Error release) -> Error (detail ^ "; download release unconfirmed: " ^ release)
  | Ok _,None -> Error "download release did not settle"
