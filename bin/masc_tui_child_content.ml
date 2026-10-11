module Read = Masc.Keeper_child_content_read
let ( let* ) = Result.bind

type error = Transport of string | Http_refused of int | Invalid_json of string
  | Invalid_response of Read.decode_error | Service of Read.failure
  | Persistence of Read.receiver * Read.error_code | Receiver_read of Read.receiver * error
  | History_rewritten of Read.receiver * string
type read_mode = Poll | Audit
type store =
  { receiver : Read.receiver; store_id : string; cursor : Read.cursor option
  ; records : Read.record list; error : error option; attempted : Read.cursor option
  ; cleanup_failures : string list; coverage : Read.coverage }
type inventory =
  { receivers : (Read.receiver * (Read.cursor,Read.error_code) result) list
  ; cleanup_failures : string list; coverage : Read.coverage }
type t =
  { keeper_name : string option; inventory : inventory option; stores : store list
  ; error : error option; audit_failures : (Read.receiver * Read.error_code) list }
let empty = {keeper_name=None;inventory=None;stores=[];error=None;audit_failures=[]}
let failed previous error = {previous with error=Some error}
let stores state = state.stores
let errors state =
  Option.to_list state.error
  @ List.map (fun (receiver,code) -> Persistence (receiver,code)) state.audit_failures
  @ List.filter_map (fun (store:store) ->
      Option.map (fun error -> Receiver_read (store.receiver,error)) store.error) state.stores
  @ (match state.inventory with None -> [] | Some inventory ->
      List.filter_map (fun (receiver,status) -> match status with
        | Ok _ -> None
        | Error code ->
            (* Audited inventory and sticky audit evidence can report the same
               scoped failure. Keep distinct codes, but publish this fact once. *)
            if List.mem (receiver,code) state.audit_failures then None
            else Some (Persistence (receiver,code))) inventory.receivers)
let code_text = function
  | Read.Store_missing -> "store missing" | Invalid_scope -> "invalid scope"
  | Invalid_observation -> "invalid observation" | Cursor_store_mismatch -> "store incarnation changed"
  | Cursor_ahead -> "cursor beyond history" | Store_corrupt -> "store corrupt"
  | Conflicting_observation -> "conflicting observation" | Sequence_exhausted -> "sequence exhausted"
  | Io_failed -> "I/O failed" | Directory_prepare_failed -> "directory unavailable"
  | Store_unavailable -> "store unavailable" | Commit_unconfirmed -> "commit unconfirmed"
  | Invalid_query -> "invalid query" | Invalid_keeper -> "invalid Keeper"
let receiver_text (receiver:Read.receiver) =
  receiver.receiver_generation ^ " / " ^ receiver.session_id ^ " / " ^ receiver.client_uuid
let rec error_text = function
  | Transport detail -> "transport: " ^ detail
  | Http_refused status -> Printf.sprintf "HTTP %d refused Child read" status
  | Invalid_json detail -> "invalid JSON: " ^ detail
  | Invalid_response error -> Read.decode_error_to_string error
  | Service failure -> code_text failure.error
  | Persistence (receiver,code) -> receiver_text receiver ^ ": " ^ code_text code
  | Receiver_read (receiver,error) -> receiver_text receiver ^ ": " ^ error_text error
  | History_rewritten (receiver,store_id) ->
      receiver_text receiver ^ ": immutable history changed in " ^ store_id
let diagnostics state =
  match state.inventory with
  | None -> []
  | Some inventory ->
      let coverage = match inventory.coverage with Read.Unavailable ->
        ["persistence failure history unavailable; provider completeness and liveness unknown"] in
      let retained = List.filter_map (fun (store:store) ->
        if List.exists (fun (receiver,status) -> receiver=store.receiver &&
          match status with Ok cursor -> cursor.Read.store_id=store.store_id | Error _ -> true)
            inventory.receivers
        then None else Some "retained Child history absent from latest inventory; current redaction unknown") state.stores in
      let cleanup = inventory.cleanup_failures @ List.concat_map
          (fun (store:store) -> store.cleanup_failures) state.stores in
      List.sort_uniq String.compare (coverage @ retained @
        List.map (fun operation -> "cleanup failed: " ^ operation) cleanup)
let decode ~fetch path =
  let* status,body=fetch path |> Result.map_error (fun detail -> Transport detail) in
  let parsed=match Yojson.Safe.from_string body with
    | json -> Read.of_json json |> Result.map_error (fun error -> Invalid_response error)
    | exception Yojson.Json_error detail -> Error (Invalid_json detail) in
  if Masc.Tui_decode.is_success_http_status status then
    let* response=parsed in
    match response with Read.Failure _ -> Error (Invalid_response Read.Unexpected_response)
      | Records _ | Receivers _ | Hints _ -> Ok response
  else match parsed with
    | Ok (Read.Failure failure) -> Error (Service failure)
    | Ok (Read.Records _ | Receivers _ | Hints _) | Error _ -> Error (Http_refused status)
let prefix keeper_name = "/api/v1/keepers/"
  ^ Uri.pct_encode ~component:(`Custom (`Path,"","/")) keeper_name ^ "/child-content/"
let records_path keeper_name (receiver:Read.receiver) after =
  let query=["receiver_generation",receiver.receiver_generation;"session_id",receiver.session_id;
      "client_uuid",receiver.client_uuid]
    @ (match after with None -> [] | Some (cursor:Read.cursor) ->
        ["store_id",cursor.store_id;"after_sequence",string_of_int cursor.after_sequence]) in
  Uri.with_query' (Uri.of_string (prefix keeper_name ^ "records")) query |> Uri.to_string

module Keys = Set.Make (struct
  type t = string * int * Runtime_claude_code.content_channel
  let compare = compare
end)
let key (row:Read.record) =
  row.observation.observation_id,row.observation.ordinal,row.observation.channel
let append_records (old:store) (page:Read.records) =
  let seen=List.fold_left (fun keys row -> Keys.add (key row) keys) Keys.empty old.records in
  let rec unique keys = function
    | [] -> Ok ()
    | row::rest -> if Keys.mem (key row) keys then Error (Invalid_response Read.Duplicate_observation)
        else unique (Keys.add (key row) keys) rest in
  let* ()=unique seen page.records in
  match page.records with [] -> Ok old.records | _::_ -> Ok (old.records @ page.records)
let same_identity (left:Read.record) (right:Read.record) =
  let a=left.observation and b=right.observation in
  left.seq=right.seq && left.recorded_at=right.recorded_at
  && a.origin=b.origin && a.observation_id=b.observation_id && a.envelope_uuid=b.envelope_uuid
  && a.ordinal=b.ordinal && a.channel=b.channel && a.parent_tool_use_id=b.parent_tool_use_id
  && a.parent_occurrence=b.parent_occurrence && a.message_id=b.message_id && a.attribution=b.attribution
let audit_records (old:store) (page:Read.records) =
  let refuse ()=Error (History_rewritten (old.receiver,old.store_id)) in
  match old.cursor with
  | Some cursor when page.next_cursor.after_sequence<cursor.after_sequence -> refuse ()
  | None | Some _ ->
      let rec prefix unchanged old_rows fresh_rows = match old_rows,fresh_rows with
        | [],[] -> Ok (if unchanged then old.records else page.records)
        | [],_::_ -> Ok page.records
        | _::_,[] -> refuse ()
        | before::old_rest,after::fresh_rest ->
            if not (same_identity before after) then refuse ()
            else prefix (unchanged && before=after) old_rest fresh_rest in
      prefix true old.records page.records

let read ~mode ~keeper_name ~fetch ~previous =
  let* ()=match previous.keeper_name with None -> Ok ()
    | Some owner when owner=keeper_name -> Ok () | Some _ -> Error (Invalid_response Read.Scope_mismatch) in
  let* inventory=match mode with
    | Poll ->
        let* response=decode ~fetch (prefix keeper_name ^ "hints") in
        let* page=Read.hints_of_response ~keeper_name response |> Result.map_error (fun error -> Invalid_response error) in
        Ok {receivers=List.map (fun (entry:Read.hint_entry) -> entry.receiver,
            match entry.hint with Read.Unchecked cursor -> Ok cursor | Hint_failed code -> Error code) page.hints;
          cleanup_failures=page.cleanup_failures;coverage=page.coverage}
    | Audit ->
        let* response=decode ~fetch (prefix keeper_name ^ "receivers") in
        let* page=Read.receivers_of_response ~keeper_name response |> Result.map_error (fun error -> Invalid_response error) in
        Ok {receivers=List.map (fun (entry:Read.entry) -> entry.receiver,
            match entry.storage with Read.Audited cursor -> Ok cursor | Failed code -> Error code) page.receivers;
          cleanup_failures=page.cleanup_failures;coverage=page.coverage} in
  let audit_failures=ref previous.audit_failures in
  (match mode with Poll -> () | Audit ->
    List.iter (fun (receiver,status) -> match status with
      | Ok _ -> ()
      | Error code -> audit_failures := (receiver,code)::List.remove_assoc receiver !audit_failures)
      inventory.receivers);
  let stores=List.fold_left (fun stores (receiver,status) -> match status with
    | Error _ -> stores
    | Ok (advertised:Read.cursor) ->
        let same (store:store)=store.receiver=receiver && store.store_id=advertised.store_id in
        let old=List.find_opt same stores in
        if mode=Poll && Option.exists (fun (store:store) ->
          store.attempted=Some advertised || (store.error=None && store.cursor=Some advertised)) old
        then stores else
        (* A suffix cannot repair evidence that the retained prefix changed.
           Keep that primary failure until a complete prefix comparison succeeds. *)
        let full = mode=Audit || Option.exists (fun (store:store) ->
          match store.error with Some (History_rewritten _) -> true | _ -> false) old in
        let after=if full then None else Option.bind old (fun (store:store) -> store.cursor) in
        let request:Read.records_request={scope={keeper_name;receiver};after} in
        let loaded=
          let* response=decode ~fetch (records_path keeper_name receiver after) in
          let* page=Read.records_of_response ~request response |> Result.map_error (fun error -> Invalid_response error) in
          let* ()=if page.next_cursor.store_id<>advertised.store_id then Error (Invalid_response Read.Cursor_mismatch)
            else if page.next_cursor.after_sequence<advertised.after_sequence then Error (Invalid_response Read.Sequence_mismatch)
            else Ok () in
          let* records=match old,full with
            | None,_ -> Ok page.records
            | Some store,false -> append_records store page
            | Some store,true -> audit_records store page in
          Ok (page,records) in
        let store=match loaded with
          | Ok (page,records) ->
              audit_failures := List.remove_assoc receiver !audit_failures;
              let fresh={receiver;store_id=advertised.store_id;cursor=Some page.next_cursor;records;error=None;
                attempted=Some advertised;cleanup_failures=page.cleanup_failures;coverage=page.coverage} in
              (match old with Some old when old=fresh -> old | None | Some _ -> fresh)
          | Error error -> (match old with
              | Some store ->
                  let primary = match store.error with
                    | Some (History_rewritten _ as retained) -> retained
                    | Some _ | None -> error in
                  {store with error=Some primary;attempted=Some advertised}
              | None -> {receiver;store_id=advertised.store_id;cursor=None;records=[];error=Some error;
                  attempted=Some advertised;cleanup_failures=[];coverage=inventory.coverage}) in
        match old with None -> stores @ [store]
          | Some old when old==store -> stores
          | Some _ -> List.map (fun old -> if same old then store else old) stores)
    previous.stores inventory.receivers in
  if previous.error=None && stores==previous.stores && previous.inventory=Some inventory
    && previous.audit_failures= !audit_failures then Ok previous
  else Ok {keeper_name=Some keeper_name;inventory=Some inventory;stores;error=None;audit_failures= !audit_failures}
