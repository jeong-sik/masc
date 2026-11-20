module Http = Http_server_eio
module Digest = Agent_core.Checkpoint_objects
module Unwritable = Keeper_tool_memory_validation

let permission = Masc_domain.CanAdmin
let prefix = Server_dashboard_http_keeper_api_types.keeper_api_prefix

let route path =
  if not (String.starts_with ~prefix path)
  then None
  else (
    match
      String.sub path (String.length prefix) (String.length path - String.length prefix)
      |> String.split_on_char '/'
    with
    | [ keeper_name; "memory"; "act" ] when keeper_name <> "" -> Some keeper_name
    | _ -> None)
;;

type action =
  | Resume
  | Adopt of { observed : Digest.digest }

let action_resume = "resume"
let action_adopt = "adopt"

let request_shape =
  Printf.sprintf
    {|the request is {"action":"%s"} or {"action":"%s","observed":"<sha256 hex>"}|}
    action_resume
    action_adopt
;;

let parse body =
  let adopt hex =
    match Digest.digest_of_hex hex with
    | Ok observed -> Ok (Adopt { observed })
    | Error detail -> Error ("observed: " ^ detail)
  in
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
  | `Assoc [ ("action", `String action) ] when String.equal action action_resume -> Ok Resume
  | `Assoc [ ("action", `String action); ("observed", `String hex) ]
  | `Assoc [ ("observed", `String hex); ("action", `String action) ]
    when String.equal action action_adopt -> adopt hex
  | _ -> Error request_shape
;;

type store =
  | Open
  | Booting
  | Stopped of Librarian_store.stop
  | No_writer

type answer =
  | Acted of store
  | Refused of Librarian_machine.act_refusal
  | No_writers

let act ~base_path ~keeper ~actor action =
  match Keeper_memory_writers.find ~base_path with
  | None -> No_writers
  | Some writers ->
    let answer =
      match action with
      | Resume -> Librarian_writers.resume writers keeper
      | Adopt { observed } -> Librarian_writers.adopt writers keeper ~by:actor ~observed
    in
    (match answer with
     | Not_done refusal -> Refused refusal
     | Done ->
       Acted
         (match Librarian_writers.view writers keeper with
          | Ok (_ : Librarian_writer.view) -> Open
          | Error `Booting -> Booting
          | Error (`Stopped stop) -> Stopped stop
          | Error `No_writer -> No_writer))
;;

let action_name = function
  | Resume -> action_resume
  | Adopt { observed = (_ : Digest.digest) } -> action_adopt
;;

(* A stopped store says why in the words the Memory tools use. A store whose
   log and snapshot disagree also names both snapshots: the one the file
   holds is what an adoption has to name. *)
let stop_fields (stop : Librarian_store.stop) =
  ( "stopped"
  , `String (Unwritable.memory_unwritable_to_string (Unwritable.Store_stopped stop)) )
  ::
  (match stop with
   | Log_diverged { expected; observed } ->
     [ "expected_snapshot", `String (expected :> string)
     ; "observed_snapshot", `String (observed :> string)
     ]
   | Raised { detail } -> [ "raised", `String detail ]
   | Memory_unreadable | Log_unreadable | Store_unwritable -> [])
;;

let store_fields = function
  | Open -> [ "store", `String "open" ]
  | Booting -> [ "store", `String "booting" ]
  | No_writer -> [ "store", `String "no_writer" ]
  | Stopped stop -> ("store", `String "stopped") :: stop_fields stop
;;

let refusal_fields : Librarian_machine.act_refusal -> (string * Yojson.Safe.t) list = function
  | Nothing_to_resume -> [ "code", `String "nothing_to_resume" ]
  | Not_stopped -> [ "code", `String "not_stopped" ]
  | Snapshot_mismatch -> [ "code", `String "snapshot_mismatch" ]
  | Snapshot_unreadable -> [ "code", `String "snapshot_unreadable" ]
  | Act_unavailable (Store_stopped stop) -> ("code", `String "store_stopped") :: stop_fields stop
  | Act_unavailable Keeper_retired -> [ "code", `String "keeper_not_registered" ]
;;

let respond request reqd ~status fields =
  Http.Response.json_value
    ~status
    ~request
    ~extra_headers:[ "cache-control", "no-store" ]
    (`Assoc fields)
    reqd
;;

let handle_post state ~actor request reqd keeper_name body =
  match parse body with
  | Error detail ->
    respond request reqd ~status:`Bad_request
      [ "ok", `Bool false; "code", `String "invalid_request"; "error", `String detail ]
  | Ok action ->
    let config = Mcp_server.workspace_config state in
    let named = [ "keeper", `String keeper_name; "action", `String (action_name action) ] in
    let answer = act ~base_path:config.Workspace.base_path ~keeper:keeper_name ~actor action in
    Log.Keeper.info
      "admin Memory writer action keeper=%s actor=%s action=%s"
      keeper_name
      actor
      (action_name action);
    (match answer with
     | Acted store -> respond request reqd ~status:`OK ((("ok", `Bool true) :: named) @ store_fields store)
     | Refused refusal ->
       respond request reqd ~status:`Conflict
         ((("ok", `Bool false) :: named) @ refusal_fields refusal)
     | No_writers ->
       respond request reqd ~status:`Service_unavailable
         ((("ok", `Bool false) :: named) @ [ "code", `String "no_writer_in_process" ]))
;;
