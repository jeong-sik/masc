module Observe = Llm_provider.Http_request_observer
module Calls = Map.Make (Int)

type t =
  { observer : Observe.t
  ; events : Observe.event list ref
  ; path : string
  }

let completion_name = function
  | Observe.Returned_ok -> "returned_ok"
  | Returned_error -> "returned_error"
  | Cancelled -> "cancelled"
  | Raised -> "raised"

let phase_json = function
  | Observe.Client_entered {mode;body_bytes;body_sha256} ->
    [ "phase",`String "client_entered"
    ; "mode",`String (match mode with Synchronous -> "synchronous" | Streaming -> "streaming")
    ; "body_bytes",`Int body_bytes; "body_sha256",`String body_sha256 ]
  | Dispatch_entered -> ["phase",`String "dispatch_entered"]
  | Response_headers_received {status} -> ["phase",`String "response_headers_received";"status",`Int status]
  | Client_finished completion -> ["phase",`String "client_finished";"completion",`String (completion_name completion)]

let create ~path ~now =
  let fd = Unix.openfile path [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_EXCL] 0o600 in
  Unix.close fd;
  let parent = Unix.openfile (Filename.dirname path) [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close parent) (fun () -> Unix.fsync parent);
  let events = ref [] in
  let observer = Observe.create (fun (event : Observe.event) ->
    let row = `Assoc (["call_id",`Int event.call_id;"observed",now ()] @ phase_json event.phase) in
    Out_channel.with_open_gen [Open_wronly;Open_creat;Open_append;Open_binary] 0o600 path (fun out ->
      output_string out (Yojson.Safe.to_string row ^ "\n");
      flush out; Unix.fsync (Unix.descr_of_out_channel out));
    events := event :: !events;
    Ok ()) in
  {observer;events;path}

let within observation run = Observe.with_observer observation.observer run

let snapshot observation =
  let events = List.rev !(observation.events) in
  let calls = List.fold_left (fun calls (event : Observe.event) ->
    Calls.update event.call_id (function None -> Some [event.phase] | Some phases -> Some (event.phase::phases)) calls)
      Calls.empty events |> Calls.map List.rev in
  let facts = Calls.bindings calls |> List.map (fun (_,phases) -> match phases with
    | [Observe.Client_entered {body_bytes;_};Dispatch_entered;Response_headers_received {status};Client_finished completion] ->
      Some (body_bytes,true,Some status,completion)
    | [Observe.Client_entered {body_bytes;_};Dispatch_entered;Client_finished (Returned_error | Cancelled | Raised as completion)] ->
      Some (body_bytes,true,None,completion)
    | [Observe.Client_entered {body_bytes;_};Client_finished (Returned_error | Cancelled | Raised as completion)] ->
      Some (body_bytes,false,None,completion)
    | _ -> None) in
  let failures = Observe.delivery_failure_count observation.observer in
  let sha_file = try
      Some Digestif.SHA256.(In_channel.with_open_bin observation.path In_channel.input_all |> digest_string |> to_hex)
    with Sys_error _ | Unix.Unix_error _ -> None in
  let complete = failures=0 && List.for_all Option.is_some facts && Option.is_some sha_file in
  let total project = if complete then `Int (List.fold_left (fun sum -> function
    | Some facts -> sum + project facts | None -> sum) 0 facts) else `Null in
  `Assoc
    [ "scope",`String "native provider HTTP POST client calls within this explicit cycle"
    ; "coverage",`String (if complete then "complete" else "unknown")
    ; "delivery_failures",`Int failures
    ; "calls_entered",total (fun _ -> 1)
    ; "dispatch_entries",total (fun (_,sent,_,_) -> if sent then 1 else 0)
    ; "response_headers_received",total (fun (_,_,status,_) -> if Option.is_some status then 1 else 0)
    ; "serialized_body_bytes",total (fun (bytes,_,_,_) -> bytes)
    ; "dispatched_body_bytes",total (fun (bytes,sent,_,_) -> if sent then bytes else 0)
    ; "client_returned_ok",total (fun (_,_,_,completion) -> match completion with Observe.Returned_ok -> 1 | Returned_error | Cancelled | Raised -> 0)
    ; "client_returned_error",total (fun (_,_,_,completion) -> match completion with Observe.Returned_error -> 1 | Returned_ok | Cancelled | Raised -> 0)
    ; "client_cancelled",total (fun (_,_,_,completion) -> match completion with Observe.Cancelled -> 1 | Returned_ok | Returned_error | Raised -> 0)
    ; "client_raised",total (fun (_,_,_,completion) -> match completion with Observe.Raised -> 1 | Returned_ok | Returned_error | Cancelled -> 0)
    ; "events_sha256",(match sha_file with None -> `Null | Some value -> `String value)
    ; "claims",`List (List.map (fun text -> `String text)
      ["body bytes are serialized/submitted payload, not peer-acknowledged network bytes";
       "response headers and client return are not a provider/parser/business-success verdict";
       "no response-reported model or first offered Tool inventory is inferred"]) ]
