type state =
  | Unavailable of
      { revision : Fleet_stream.Revision.t
      ; degradation : Fleet_stream.degradation
      }
  | Measured of
  { revision : Fleet_stream.Revision.t
  ; measured_at : float
  ; fleet : Fleet_stream.fleet
  ; degraded : Fleet_stream.degradation option
  }

type subscriber =
  { id : int
  ; on_event : Fleet_stream.event -> unit
  }

type t =
  { mutex : Mutex.t
  ; on_subscriber_error : exn -> unit
  ; mutable state : state option
  ; mutable subscribers : subscriber list
  ; mutable next_id : int
  }

let create ~on_subscriber_error =
  { mutex = Mutex.create ()
  ; on_subscriber_error
  ; state = None
  ; subscribers = []
  ; next_id = 0
  }
;;

let snapshot_of_state (state : state) : Fleet_stream.event =
  match state with
  | Unavailable { revision; degradation } -> Unavailable_snapshot { revision; degradation }
  | Measured state -> Snapshot
    { revision = state.revision
    ; measured_at = state.measured_at
    ; fleet = state.fleet
    ; degraded = state.degraded
    }
;;

(* Calls every subscriber with [event]. A subscriber that raises is dropped from
   the list and handed back with what it raised. *)
let deliver t event =
  let failures =
    List.filter_map
      (fun subscriber ->
         match subscriber.on_event event with
         | () -> None
         | exception exn -> Some (subscriber.id, exn))
      t.subscribers
  in
  (match failures with
   | [] -> ()
   | _ :: _ ->
     t.subscribers
     <- List.filter
          (fun subscriber -> not (List.mem_assoc subscriber.id failures))
          t.subscribers);
  List.map snd failures
;;

(* Runs [f] with the lock held and reports the subscriber failures it returns
   after the lock is released. *)
let locked t f =
  let failures = Mutex.protect t.mutex f in
  List.iter t.on_subscriber_error failures
;;

let observe t ~measured_at fleet =
  locked t (fun () ->
    match t.state with
    | None ->
      let state =
        Measured { revision = Fleet_stream.Revision.first; measured_at; fleet; degraded = None }
      in
      t.state <- Some state;
      deliver t (snapshot_of_state state)
    | Some (Unavailable previous) ->
      let revision = Fleet_stream.Revision.next previous.revision in
      t.state <- Some (Measured { revision; measured_at; fleet; degraded = None });
      deliver t (Changed { revision; measured_at; fleet })
    | Some (Measured previous) ->
      (match previous.degraded with
       | None when Fleet_stream.equal_fleet previous.fleet fleet ->
         t.state <- Some (Measured { previous with measured_at });
         []
       | None | Some _ ->
         let revision = Fleet_stream.Revision.next previous.revision in
         t.state <- Some (Measured { revision; measured_at; fleet; degraded = None });
         deliver t (Changed { revision; measured_at; fleet })))
;;

let note_degraded t ~since reason =
  locked t (fun () ->
    match t.state with
    | None ->
      let revision = Fleet_stream.Revision.first in
      let degradation = { Fleet_stream.since; reason } in
      t.state <- Some (Unavailable { revision; degradation });
      deliver t (Unavailable_snapshot { revision; degradation })
    | Some (Unavailable _ | Measured { degraded = Some _; _ }) -> []
    | Some (Measured ({ degraded = None; _ } as previous)) ->
      let revision = Fleet_stream.Revision.next previous.revision in
      let degradation = { Fleet_stream.since; reason } in
      t.state <- Some (Measured { previous with revision; degraded = Some degradation });
      deliver t (Degraded { revision; degradation }))
;;

let subscribe t ~on_event =
  let id = ref None in
  locked t (fun () ->
    let subscriber = { id = t.next_id; on_event } in
    t.next_id <- t.next_id + 1;
    let started =
      match t.state with
      | None -> Ok ()
      | Some state ->
        (match on_event (snapshot_of_state state) with
         | () -> Ok ()
         | exception exn -> Error exn)
    in
    match started with
    | Ok () ->
      t.subscribers <- t.subscribers @ [ subscriber ];
      id := Some subscriber.id;
      []
    | Error exn -> [ exn ]);
  fun () ->
    match !id with
    | None -> ()
    | Some id ->
      Mutex.protect t.mutex (fun () ->
        t.subscribers <- List.filter (fun subscriber -> subscriber.id <> id) t.subscribers)
;;

let current t =
  Mutex.protect t.mutex (fun () -> Option.map snapshot_of_state t.state)
;;
