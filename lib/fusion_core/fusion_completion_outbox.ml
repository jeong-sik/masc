module Completion_address = struct
  type t = Address of string [@@deriving yojson, show, eq]

  let of_opaque_string value = Address value
  let to_opaque_string (Address value) = value
end

type completion_payload =
  { content : string
  ; evidence_ref : string option
  }
[@@deriving yojson, show, eq]

type completion =
  | Succeeded of completion_payload
  | Failed of completion_payload
[@@deriving yojson, show, eq]

type item =
  { operation_id : string
  ; address : Completion_address.t
  ; completion : completion
  }
[@@deriving show, eq]

type error =
  | Persistence_failed of { path : string; detail : string }
  | Unknown_address of string
  | Address_conflict of string
  | Completion_conflict of string
  | Unknown_completion of string

type registration =
  { operation_id : string
  ; address : Completion_address.t
  }
[@@deriving yojson]

type completion_event =
  { operation_id : string
  ; completion : completion
  }
[@@deriving yojson]

type event =
  | Registered_address of registration
  | Queued_completion of completion_event
  | Acknowledged_completion of string
[@@deriving yojson]

type register_receipt = Registered | Already_registered
type completion_receipt = Queued | Already_pending | Already_delivered
type acknowledgement_receipt = Acknowledged | Already_acknowledged

module By_id = Map.Make (String)

type state =
  { addresses : Completion_address.t By_id.t
  ; pending : item By_id.t
  ; delivered : completion By_id.t
  }

type t =
  { state : state Atomic.t
  ; path : string option
  ; lock : Mutex.t
  }

let empty = { addresses = By_id.empty; pending = By_id.empty; delivered = By_id.empty }
let create ?path () = { state = Atomic.make empty; path; lock = Mutex.create () }

let error_to_string = function
  | Persistence_failed { path; detail } ->
    Printf.sprintf "fusion completion outbox write failed for %s: %s" path detail
  | Unknown_address id -> Printf.sprintf "fusion operation %s has no completion address" id
  | Address_conflict id -> Printf.sprintf "fusion operation %s has a conflicting address" id
  | Completion_conflict id -> Printf.sprintf "fusion operation %s has a conflicting completion" id
  | Unknown_completion id -> Printf.sprintf "fusion operation %s has no pending completion" id
;;

let apply_event state = function
  | Registered_address { operation_id; address } ->
    (match By_id.find_opt operation_id state.addresses with
     | None -> Ok { state with addresses = By_id.add operation_id address state.addresses }
     | Some existing when Completion_address.equal existing address -> Ok state
     | Some _ -> Error (Address_conflict operation_id))
  | Queued_completion { operation_id; completion } ->
    (match By_id.find_opt operation_id state.pending, By_id.find_opt operation_id state.delivered with
     | Some item, _ when equal_completion item.completion completion -> Ok state
     | Some _, _ -> Error (Completion_conflict operation_id)
     | None, Some existing when equal_completion existing completion -> Ok state
     | None, Some _ -> Error (Completion_conflict operation_id)
     | None, None ->
       (match By_id.find_opt operation_id state.addresses with
        | None -> Error (Unknown_address operation_id)
        | Some address ->
          let item = { operation_id; address; completion } in
          Ok { state with pending = By_id.add operation_id item state.pending }))
  | Acknowledged_completion operation_id ->
    (match By_id.find_opt operation_id state.pending with
     | Some item ->
       Ok
         { state with
           pending = By_id.remove operation_id state.pending
         ; delivered = By_id.add operation_id item.completion state.delivered
         }
     | None when By_id.mem operation_id state.delivered -> Ok state
     | None -> Error (Unknown_completion operation_id))
;;

let append t event =
  match t.path with
  | None -> Ok ()
  | Some path ->
    (try
       Fs_compat.append_jsonl path (event_to_yojson event);
       Ok ()
     with
     | exn ->
       let error = Persistence_failed { path; detail = Printexc.to_string exn } in
       Log.Misc.error "%s" (error_to_string error);
       Error error)
;;

type commit = Changed of state | Unchanged of state

let commit t event =
  Mutex.protect t.lock (fun () ->
    let before = Atomic.get t.state in
    match apply_event before event with
    | Error _ as error -> error
    | Ok after when before == after -> Ok (Unchanged after)
    | Ok after ->
      (match append t event with
       | Error _ as error -> error
       | Ok () ->
         Atomic.set t.state after;
         Ok (Changed after)))
;;

let register_address t ~operation_id address =
  commit t (Registered_address { operation_id; address })
  |> Result.map (function Changed _ -> Registered | Unchanged _ -> Already_registered)
;;

let complete t ~operation_id completion =
  commit t (Queued_completion { operation_id; completion })
  |> Result.map (function
    | Changed _ -> Queued
    | Unchanged state ->
      if By_id.mem operation_id state.delivered then Already_delivered else Already_pending)
;;

let acknowledge t ~operation_id =
  commit t (Acknowledged_completion operation_id)
  |> Result.map (function Changed _ -> Acknowledged | Unchanged _ -> Already_acknowledged)
;;

let pending t = Atomic.get t.state |> fun state -> By_id.bindings state.pending |> List.map snd
let registered_address t ~operation_id = By_id.find_opt operation_id (Atomic.get t.state).addresses

let replay path =
  if not (Fs_compat.file_exists path)
  then create ~path ()
  else (
  let state, errors =
    try
      let (state, errors, _), _ =
        Fs_compat.fold_appended_lines ~path ~from:0 ~init:(empty, [], 1)
          ~f:(fun (state, errors, line_no) line ->
            let parsed =
              try event_of_yojson (Yojson.Safe.from_string line) with
              | exn -> Error (Printexc.to_string exn)
            in
            match parsed with
            | Error detail -> state, (line_no, detail) :: errors, line_no + 1
            | Ok event ->
              (match apply_event state event with
               | Ok state -> state, errors, line_no + 1
               | Error error -> state, (line_no, error_to_string error) :: errors, line_no + 1))
      in
      state, List.rev errors
    with
    | exn ->
      Log.Misc.error "fusion completion outbox replay failed for %s: %s" path (Printexc.to_string exn);
      empty, []
  in
  (match errors with
   | [] -> ()
   | (line_no, detail) :: _ ->
     Log.Misc.error
       "fusion completion outbox skipped %d invalid event(s); first=%s:%d: %s"
       (List.length errors) path line_no detail);
  { state = Atomic.make state; path = Some path; lock = Mutex.create () })
;;

let global_state = Atomic.make (create ())
let global () = Atomic.get global_state
let set_global value = Atomic.set global_state value
