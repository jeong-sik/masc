type line =
  { seq : int
  ; stream_id : int option
  ; task_id : string option
  ; stream : string
  ; text : string
  }

type active =
  { id : int
  ; task : string option
  ; command : string
  }

type reading =
  { lines : line list
  ; active : active list
  ; lines_omitted : int
  ; first_seq : int
  ; active_count : int
  ; closed : bool
  ; status : Yojson.Safe.t
  ; observed_at : float
  }

type view =
  | Awaiting_first_frame
  | Nothing_observed
  | Observed of reading

type failure =
  | Frame_rejected of string
  | Another_keeper of { expected : string; received : string }
  | Events_lost of { from_seq : int; to_seq : int }
  | Out_of_order of { expected : int; received : int }

let failure_to_string = function
  | Frame_rejected detail ->
    "the Execute output stream sent a frame this build cannot read: " ^ detail
  | Another_keeper { expected; received } ->
    Printf.sprintf "the Execute output stream is for %s, not %s" received expected
  | Events_lost { from_seq; to_seq } ->
    Printf.sprintf "Execute output rows %d to %d were dropped on the way" from_seq to_seq
  | Out_of_order { expected; received } ->
    Printf.sprintf "Execute output row %d arrived where row %d was expected" received expected
;;

type step =
  | Keep_reading
  | Reconnect of failure

(* What the server sends, read from JSON. The server's own names for the
   fields are kept: a reader that renamed them would hide the contract. *)
type event =
  | Snapshot of
      { rows : line list
      ; running : active list
      ; first_retained : int
      ; last : int
      ; active_count : int
      ; closed : bool
      ; status : Yojson.Safe.t
      }
  | No_task
  | Row of line
  | Opened of
      { seq : int
      ; id : int
      ; task : string option
      }
  | Closed of
      { seq : int
      ; id : int option
      ; task : string option
      ; active_count : int
      ; closed : bool
      ; status : Yojson.Safe.t
      }
  | Gap of
      { from_seq : int
      ; to_seq : int
      }

let ( let* ) = Result.bind

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let wrong name expected = Error (Printf.sprintf "%s is not %s" name expected)
let read_int name = function `Int value -> Ok value | _ -> wrong name "an integer"
let read_string name = function `String value -> Ok value | _ -> wrong name "a string"
let read_bool name = function `Bool value -> Ok value | _ -> wrong name "a boolean"

let required name read json =
  match field name json with
  | Some value -> read name value
  | None -> Error (name ^ " is missing")
;;

(* Absent and [null] both mean "none"; any other type is a malformed frame. *)
let optional name read json =
  match field name json with
  | None | Some `Null -> Ok None
  | Some value -> Result.map Option.some (read name value)
;;

let read_list name read = function
  | `List items ->
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match read item with
         | Ok value -> go (value :: acc) rest
         | Error _ as error -> error)
    in
    go [] items
  | _ -> wrong name "a list"
;;

let decode_line json =
  let* seq = required "seq" read_int json in
  let* stream_id = optional "stream_id" read_int json in
  let* task_id = optional "task_id" read_string json in
  let* stream = required "stream" read_string json in
  let* text = required "text" read_string json in
  Ok { seq; stream_id; task_id; stream; text }
;;

let decode_active json =
  let* id = required "stream_id" read_int json in
  let* task = optional "task_id" read_string json in
  let* command = required "command" read_string json in
  Ok { id; task; command }
;;

let json_status json = Option.value (field "status" json) ~default:`Null

let decode_event kind json =
  match kind with
  | "snapshot" ->
    let* rows = required "lines" (fun name -> read_list name decode_line) json in
    let* running = required "active_streams" (fun name -> read_list name decode_active) json in
    let* first_retained = required "first_retained_seq" read_int json in
    let* last = required "last_seq" read_int json in
    let* active_count = required "active_count" read_int json in
    let* closed = required "closed" read_bool json in
    Ok (Snapshot { rows; running; first_retained; last; active_count; closed; status = json_status json })
  | "no_task" -> Ok No_task
  | "line" ->
    let* line = required "line" (fun _ value -> decode_line value) json in
    Ok (Row line)
  | "task_opened" ->
    let* seq = required "seq" read_int json in
    let* id = required "stream_id" read_int json in
    let* task = optional "task_id" read_string json in
    Ok (Opened { seq; id; task })
  | "task_closed" ->
    let* seq = required "seq" read_int json in
    let* id = optional "stream_id" read_int json in
    let* task = optional "task_id" read_string json in
    let* active_count = required "active_count" read_int json in
    let* closed = required "closed" read_bool json in
    Ok (Closed { seq; id; task; active_count; closed; status = json_status json })
  | "gap" ->
    let* from_seq = required "missing_from_seq" read_int json in
    let* to_seq = required "missing_to_seq" read_int json in
    Ok (Gap { from_seq; to_seq })
  | other -> Error (Printf.sprintf "unknown event type %S" other)
;;

let decode json =
  let* kind = required "type" read_string json in
  let* keeper = required "keeper" read_string json in
  let* event = decode_event kind json in
  Ok (keeper, event)
;;

type phase =
  | Awaiting
  | Nothing
  | Observing

(* [synced] is set by this connection's snapshot and cleared when a frame is
   refused, so an event never lands on rows from another connection.
   [following] is the number of the last event of this connection; it is
   [None] after [no_task], which carries no number, and the next event then
   sets it. *)
type t =
  { keeper : string
  ; capacity : int
  ; mutable decoder : Sse_wire.decoder
  ; mutable phase : phase
  ; mutable synced : bool
  ; mutable following : int option
  ; rows : line Queue.t
  ; mutable omitted : int
  ; mutable first_seq : int
  ; mutable active : active list
  ; mutable active_count : int
  ; mutable closed : bool
  ; mutable status : Yojson.Safe.t
  ; mutable observed_at : float
  ; mutable version : int
  }

let create ~keeper ~capacity =
  if capacity < 1 then invalid_arg "Masc_tui_execute_stream.create: capacity must be positive";
  { keeper = String.lowercase_ascii (String.trim keeper)
  ; capacity
  ; decoder = Sse_wire.create_decoder ()
  ; phase = Awaiting
  ; synced = false
  ; following = None
  ; rows = Queue.create ()
  ; omitted = 0
  ; first_seq = 1
  ; active = []
  ; active_count = 0
  ; closed = true
  ; status = `Null
  ; observed_at = 0.0
  ; version = 0
  }
;;

let started t =
  t.decoder <- Sse_wire.create_decoder ();
  t.synced <- false;
  t.following <- None
;;

let reject t failure =
  t.synced <- false;
  t.following <- None;
  Reconnect failure
;;

let push_row t line =
  Queue.push line t.rows;
  if Queue.length t.rows > t.capacity
  then (
    ignore (Queue.pop t.rows : line);
    t.omitted <- t.omitted + 1)
;;

let take_snapshot t ~rows ~running ~first_retained ~last ~active_count ~closed ~status =
  Queue.clear t.rows;
  let held_from = max 0 (List.length rows - t.capacity) in
  List.iteri (fun index line -> if index >= held_from then Queue.push line t.rows) rows;
  t.omitted <- held_from;
  t.first_seq <- first_retained;
  t.active <- running;
  t.active_count <- active_count;
  t.closed <- closed;
  t.status <- status;
  t.following <- Some last;
  t.phase <- Observing;
  t.synced <- true;
  Keep_reading
;;

let take_nothing t =
  Queue.clear t.rows;
  t.omitted <- 0;
  t.first_seq <- 1;
  t.active <- [];
  t.active_count <- 0;
  t.closed <- true;
  t.status <- `Null;
  t.following <- None;
  t.phase <- Nothing;
  t.synced <- true;
  Keep_reading
;;

(* A command that began after the snapshot is named by the first row of its
   [cmd] rows. The server writes the command as rows split at line breaks and
   at its row limit, so joining them back would guess where the breaks were. *)
let name_command t line =
  match line.stream, line.stream_id with
  | "cmd", Some id ->
    t.active
    <- List.map
         (fun active ->
            if active.id = id && String.equal active.command ""
            then { active with command = line.text }
            else active)
         t.active
  | _, (Some _ | None) -> ()
;;

(* Events arrive after a snapshot that said nothing was observed, or after one
   whose last command had ended: either way the Keeper is no longer idle. *)
let become_observing t =
  match t.phase with
  | Nothing ->
    t.phase <- Observing;
    t.closed <- false
  | Awaiting | Observing -> ()
;;

let take_row t line =
  become_observing t;
  push_row t line;
  name_command t line
;;

let take_opened t ~id ~task =
  become_observing t;
  t.active
  <- List.filter (fun active -> active.id <> id) t.active @ [ { id; task; command = "" } ];
  t.active_count <- t.active_count + 1;
  t.closed <- false
;;

(* A snapshot lists a retained close as a [status] row; a live reader gets the
   same close as an event and builds the same row. *)
let take_closed t ~seq ~id ~task ~active_count ~closed ~status =
  become_observing t;
  push_row
    t
    { seq
    ; stream_id = id
    ; task_id = task
    ; stream = "status"
    ; text = Dashboard_execute_output.closed_status_text status
    };
  t.active
  <- (match id with
      | Some ended -> List.filter (fun active -> active.id <> ended) t.active
      | None -> t.active);
  t.active_count <- active_count;
  t.closed <- closed;
  t.status <- status
;;

let next t ~seq take =
  if not t.synced
  then reject t (Frame_rejected "an event came before the snapshot")
  else (
    match t.following with
    | Some last when seq <> last + 1 ->
      reject t (Out_of_order { expected = last + 1; received = seq })
    | Some _ | None ->
      t.following <- Some seq;
      take ();
      Keep_reading)
;;

let apply t (keeper, event) =
  if not (String.equal keeper t.keeper)
  then reject t (Another_keeper { expected = t.keeper; received = keeper })
  else (
    match event with
    | Snapshot { rows; running; first_retained; last; active_count; closed; status } ->
      take_snapshot t ~rows ~running ~first_retained ~last ~active_count ~closed ~status
    | No_task -> take_nothing t
    | Gap { from_seq; to_seq } -> reject t (Events_lost { from_seq; to_seq })
    | Row line -> next t ~seq:line.seq (fun () -> take_row t line)
    | Opened { seq; id; task } -> next t ~seq (fun () -> take_opened t ~id ~task)
    | Closed { seq; id; task; active_count; closed; status } ->
      next t ~seq (fun () -> take_closed t ~seq ~id ~task ~active_count ~closed ~status))
;;

let apply_frame t (frame : Sse_wire.frame) =
  match Yojson.Safe.from_string frame.data with
  | exception Yojson.Json_error detail -> reject t (Frame_rejected ("not JSON: " ^ detail))
  | json ->
    (match decode json with
     | Ok decoded -> apply t decoded
     | Error detail -> reject t (Frame_rejected detail))
;;

let feed t ~now chunk =
  let frames = Sse_wire.feed t.decoder chunk in
  let rec apply_all = function
    | [] -> Keep_reading
    | frame :: later ->
      (match apply_frame t frame with
       | Keep_reading -> apply_all later
       | Reconnect _ as step -> step)
  in
  let step = apply_all frames in
  if t.synced then t.observed_at <- now;
  if t.synced || not (List.is_empty frames) then t.version <- t.version + 1;
  step
;;

let reading t =
  { lines = List.of_seq (Queue.to_seq t.rows)
  ; active = List.filter (fun active -> not (String.equal active.command "")) t.active
  ; lines_omitted = t.omitted
  ; first_seq = t.first_seq
  ; active_count = t.active_count
  ; closed = t.closed
  ; status = t.status
  ; observed_at = t.observed_at
  }
;;

let view t =
  match t.phase with
  | Awaiting -> Awaiting_first_frame
  | Nothing -> Nothing_observed
  | Observing -> Observed (reading t)
;;

let version t = t.version
