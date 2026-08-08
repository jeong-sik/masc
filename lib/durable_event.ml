(** Event-sourced agent loop journal.

    Append-only event log for agent loop actions.
    Enables crash recovery via journal replay.

    @since 0.89.0 *)

(* ── Event types ──────────────────────────────────── *)

type envelope_v2 = Event_envelope.t

let mk_envelope_v2 = Event_envelope.make

type event =
  | Turn_started of
      { turn : int
      ; timestamp : float
      }
  | Llm_request of
      { turn : int
      ; model : string
      ; timestamp : float
      }
  | Llm_response of
      { turn : int
      ; input_tokens : int option
      ; output_tokens : int option
      ; stop_reason : string
      ; duration_ms : float
      ; timestamp : float
      }
  | Tool_called of
      { turn : int
      ; tool_name : string
      ; idempotency_key : string
      ; input_hash : string
      ; timestamp : float
      }
  | Tool_completed of
      { turn : int
      ; tool_name : string
      ; idempotency_key : string
      ; output_json : Yojson.Safe.t
      ; is_error : bool
      ; duration_ms : float
      ; timestamp : float
      }
  | State_transition of
      { from_state : string
      ; to_state : string
      ; reason : string
      ; timestamp : float
      }
  | Checkpoint_saved of
      { checkpoint_id : string
      ; timestamp : float
      }
  | Error_occurred of
      { turn : int
      ; error_domain : string
      ; detail : string
      ; timestamp : float
      }

(* ── Journal ──────────────────────────────────────── *)

type journal =
  { state : (event list * int) Atomic.t
    (** Stored as [(reversed entries, size)]. Atomic pair so reads and writes
        are lock-free and safe when the journal is appended from parallel
        concurrent tool-execution fibers. *)
  ; on_append : (event -> unit) option
    (** Optional fan-out callback invoked after every append.
        Used to project journal events onto Event_bus or other sinks. *)
  }

let create ?on_append () = { state = Atomic.make ([], 0); on_append }

type append_error =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

let append journal event =
  let rec loop () =
    let old_state = Atomic.get journal.state in
    let old_entries, old_size = old_state in
    let new_state = event :: old_entries, old_size + 1 in
    if not (Atomic.compare_and_set journal.state old_state new_state) then loop ()
  in
  loop ();
  (* The durable state is committed before fan-out. Observer failure is
     explicit, but never rolls the event back. *)
  match journal.on_append with
  | None -> Ok ()
  | Some callback ->
    (try
       callback event;
       Ok ()
     with
     | exception_ ->
       let backtrace = Printexc.get_raw_backtrace () in
       (match exception_ with
        | Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _ ->
          Printexc.raise_with_backtrace exception_ backtrace
        | _ -> Error { exception_; backtrace }))
;;

let events journal =
  let entries, _size = Atomic.get journal.state in
  List.rev entries
;;

let length journal =
  let _entries, size = Atomic.get journal.state in
  size
;;

(* ── Idempotency ──────────────────────────────────── *)

(** Stable idempotency key using a tagged FNV-1a hash for better distribution.
    Not cryptographic, but sufficient for deduplication within a single
    journal. Collisions are theoretically possible but practically
    unlikely for distinct tool inputs.

    Stability scope: the derived [idempotency_key] is persisted in the
    JSONL journal ([save_to_file]) and compared by equality during replay
    ([load_from_file] then [find_completed_activity]). The key carries an
    explicit hash-algorithm tag, so future algorithm changes can produce a
    new tagged key instead of silently reusing the same key namespace.
    Replaying journals written before this tag still misses the dedup
    lookup once and may re-run side-effectful tools once; callers that
    require cross-build exactly-once effects must provide external
    idempotency. *)
let idempotency_hash_tag = "fnv1a63-v2"

let fnv1a_hash (s : string) : int =
  let basis = 0x811c9dc5 in
  let prime = 0x01000193 in
  (* FNV-1a: XOR the hash with the byte first, then multiply by the prime.
     Keep the XOR in a separate binding so precedence cannot change the
     algorithm.
     This is the project-local OCaml-int variant: it uses the 32-bit FNV
     constants, then masks the native int result to a positive 63-bit value.
     See https://en.wikipedia.org/wiki/Fowler%E2%80%93Noll%E2%80%93Vo_hash_function *)
  String.fold_left
    (fun h c ->
       let h = h lxor Char.code c in
       h * prime)
    basis
    s
  land max_int (* ensure positive, 63-bit on 64-bit OCaml *)
;;

let make_idempotency_key ~tool_name ~input =
  let input_str = Yojson.Safe.to_string input in
  let hash = fnv1a_hash (tool_name ^ ":" ^ input_str) in
  Printf.sprintf "%s:%s:%08x" tool_name idempotency_hash_tag hash
;;

let find_completed_activity journal key =
  let entries, _size = Atomic.get journal.state in
  List.find_map
    (fun event ->
       match event with
       | Tool_completed { idempotency_key; output_json; _ } when idempotency_key = key ->
         Some output_json
       | _ -> None)
    entries (* entries is reversed, so finds most recent first *)
;;

(* ── Replay ───────────────────────────────────────── *)

type replay_summary =
  { last_turn : int
  ; completed_tools : (string * Yojson.Safe.t) list
  ; last_state : string
  ; total_input_tokens : int option
  ; total_output_tokens : int option
  ; error_count : int
  }

(* Fold over entries directly (reverse chronological) — avoids List.rev allocation *)
let replay_summary journal =
  let entries, _size = Atomic.get journal.state in
  let add_observed total observed =
    match total, observed with
    | Some total, Some observed -> Some (total + observed)
    | None, _ | _, None -> None
  in
  let acc =
    List.fold_left
      (fun (lt, ct, ls, it, ot, ec) event ->
         match event with
         | Turn_started { turn; _ } -> max lt turn, ct, ls, it, ot, ec
         | Llm_response { input_tokens; output_tokens; _ } ->
           lt, ct, ls, add_observed it input_tokens, add_observed ot output_tokens, ec
         | Tool_completed { idempotency_key; output_json; _ } ->
           lt, (idempotency_key, output_json) :: ct, ls, it, ot, ec
         | State_transition { to_state; _ } -> lt, ct, to_state, it, ot, ec
         | Error_occurred _ -> lt, ct, ls, it, ot, ec + 1
         | Llm_request _ | Tool_called _ | Checkpoint_saved _ -> lt, ct, ls, it, ot, ec)
      (0, [], "unknown", Some 0, Some 0, 0)
      entries
  in
  let ( last_turn
      , completed_tools_rev
      , last_state
      , total_input_tokens
      , total_output_tokens
      , error_count )
    =
    acc
  in
  { last_turn
  ; completed_tools = List.rev completed_tools_rev
  ; last_state
  ; total_input_tokens
  ; total_output_tokens
  ; error_count
  }
;;

(* ── Queries ──────────────────────────────────────── *)

let events_for_turn journal turn =
  List.filter
    (fun event ->
       match event with
       | Turn_started { turn = t; _ }
       | Llm_request { turn = t; _ }
       | Llm_response { turn = t; _ }
       | Tool_called { turn = t; _ }
       | Tool_completed { turn = t; _ }
       | Error_occurred { turn = t; _ } -> t = turn
       | State_transition _ | Checkpoint_saved _ -> false)
    (events journal)
;;

let last_timestamp journal =
  let entries, _size = Atomic.get journal.state in
  match entries with
  | [] -> None
  | first :: _ ->
    let ts =
      match first with
      | Turn_started { timestamp; _ }
      | Llm_request { timestamp; _ }
      | Llm_response { timestamp; _ }
      | Tool_called { timestamp; _ }
      | Tool_completed { timestamp; _ }
      | State_transition { timestamp; _ }
      | Checkpoint_saved { timestamp; _ }
      | Error_occurred { timestamp; _ } -> timestamp
    in
    Some ts
;;

let tool_completions journal =
  List.filter_map
    (fun event ->
       match event with
       | Tool_completed { idempotency_key; output_json; is_error; _ } ->
         Some (idempotency_key, output_json, is_error)
       | _ -> None)
    (events journal)
;;

(* ── Serialization ────────────────────────────────── *)

let event_to_json = function
  | Turn_started { turn; timestamp } ->
    `Assoc
      [ "type", `String "turn_started"; "turn", `Int turn; "timestamp", `Float timestamp ]
  | Llm_request { turn; model; timestamp } ->
    `Assoc
      [ "type", `String "llm_request"
      ; "turn", `Int turn
      ; "model", `String model
      ; "timestamp", `Float timestamp
      ]
  | Llm_response
      { turn; input_tokens; output_tokens; stop_reason; duration_ms; timestamp } ->
    `Assoc
      [ "type", `String "llm_response"
      ; "turn", `Int turn
      ; "input_tokens", Option.fold ~none:`Null ~some:(fun n -> `Int n) input_tokens
      ; "output_tokens", Option.fold ~none:`Null ~some:(fun n -> `Int n) output_tokens
      ; "stop_reason", `String stop_reason
      ; "duration_ms", `Float duration_ms
      ; "timestamp", `Float timestamp
      ]
  | Tool_called { turn; tool_name; idempotency_key; input_hash; timestamp } ->
    `Assoc
      [ "type", `String "tool_called"
      ; "turn", `Int turn
      ; "tool_name", `String tool_name
      ; "idempotency_key", `String idempotency_key
      ; "input_hash", `String input_hash
      ; "timestamp", `Float timestamp
      ]
  | Tool_completed
      { turn; tool_name; idempotency_key; output_json; is_error; duration_ms; timestamp }
    ->
    `Assoc
      [ "type", `String "tool_completed"
      ; "turn", `Int turn
      ; "tool_name", `String tool_name
      ; "idempotency_key", `String idempotency_key
      ; "output_json", output_json
      ; "is_error", `Bool is_error
      ; "duration_ms", `Float duration_ms
      ; "timestamp", `Float timestamp
      ]
  | State_transition { from_state; to_state; reason; timestamp } ->
    `Assoc
      [ "type", `String "state_transition"
      ; "from_state", `String from_state
      ; "to_state", `String to_state
      ; "reason", `String reason
      ; "timestamp", `Float timestamp
      ]
  | Checkpoint_saved { checkpoint_id; timestamp } ->
    `Assoc
      [ "type", `String "checkpoint_saved"
      ; "checkpoint_id", `String checkpoint_id
      ; "timestamp", `Float timestamp
      ]
  | Error_occurred { turn; error_domain; detail; timestamp } ->
    `Assoc
      [ "type", `String "error_occurred"
      ; "turn", `Int turn
      ; "error_domain", `String error_domain
      ; "detail", `String detail
      ; "timestamp", `Float timestamp
      ]
;;

let required_nullable_int_field json ~event_type field =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | None -> Error (Printf.sprintf "%s requires field %S" event_type field)
     | Some `Null -> Ok None
     | Some (`Int value) -> Ok (Some value)
     | Some _ ->
       Error (Printf.sprintf "%s field %S must be an integer or null" event_type field))
  | _ -> Error "durable event must be a JSON object"
;;

let event_of_json json =
  let open Yojson.Safe.Util in
  try
    let typ = json |> member "type" |> to_string in
    match typ with
    | "turn_started" ->
      Ok
        (Turn_started
           { turn = json |> member "turn" |> to_int
           ; timestamp = json |> member "timestamp" |> to_float
           })
    | "llm_request" ->
      (match json with
       | `Assoc fields when List.mem_assoc "input_tokens" fields ->
         Error "llm_request does not accept legacy field \"input_tokens\""
       | `Assoc _ ->
         Ok
           (Llm_request
              { turn = json |> member "turn" |> to_int
              ; model = json |> member "model" |> to_string
              ; timestamp = json |> member "timestamp" |> to_float
              })
       | _ -> Error "durable event must be a JSON object")
    | "llm_response" ->
      let ( let* ) = Result.bind in
      let* input_tokens =
        required_nullable_int_field json ~event_type:"llm_response" "input_tokens"
      in
      let* output_tokens =
        required_nullable_int_field json ~event_type:"llm_response" "output_tokens"
      in
      Ok
        (Llm_response
           { turn = json |> member "turn" |> to_int
           ; input_tokens
           ; output_tokens
           ; stop_reason = json |> member "stop_reason" |> to_string
           ; duration_ms = json |> member "duration_ms" |> to_float
           ; timestamp = json |> member "timestamp" |> to_float
           })
    | "tool_called" ->
      Ok
        (Tool_called
           { turn = json |> member "turn" |> to_int
           ; tool_name = json |> member "tool_name" |> to_string
           ; idempotency_key = json |> member "idempotency_key" |> to_string
           ; input_hash = json |> member "input_hash" |> to_string
           ; timestamp = json |> member "timestamp" |> to_float
           })
    | "tool_completed" ->
      Ok
        (Tool_completed
           { turn = json |> member "turn" |> to_int
           ; tool_name = json |> member "tool_name" |> to_string
           ; idempotency_key = json |> member "idempotency_key" |> to_string
           ; output_json = json |> member "output_json"
           ; is_error = json |> member "is_error" |> to_bool
           ; duration_ms = json |> member "duration_ms" |> to_float
           ; timestamp = json |> member "timestamp" |> to_float
           })
    | "state_transition" ->
      Ok
        (State_transition
           { from_state = json |> member "from_state" |> to_string
           ; to_state = json |> member "to_state" |> to_string
           ; reason = json |> member "reason" |> to_string
           ; timestamp = json |> member "timestamp" |> to_float
           })
    | "checkpoint_saved" ->
      Ok
        (Checkpoint_saved
           { checkpoint_id = json |> member "checkpoint_id" |> to_string
           ; timestamp = json |> member "timestamp" |> to_float
           })
    | "error_occurred" ->
      Ok
        (Error_occurred
           { turn = json |> member "turn" |> to_int
           ; error_domain = json |> member "error_domain" |> to_string
           ; detail = json |> member "detail" |> to_string
           ; timestamp = json |> member "timestamp" |> to_float
           })
    | unknown -> Error (Printf.sprintf "unknown event type: %s" unknown)
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error msg
;;

let journal_to_json journal = `List (List.map event_to_json (events journal))

let journal_of_json json =
  let open Yojson.Safe.Util in
  try
    let items = to_list json in
    (* acc accumulates in reverse — matches the reversed internal entries format *)
    let rec parse acc count = function
      | [] -> Ok { state = Atomic.make (acc, count); on_append = None }
      | item :: rest ->
        (match event_of_json item with
         | Ok evt -> parse (evt :: acc) (count + 1) rest
         | Error e -> Error e)
    in
    parse [] 0 items
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error msg
;;

(* ── Persistence (JSONL) ─────────────────────────── *)

let save_to_file journal path =
  (* Delegate to {!Fs_result.write_file}: unique per-writer tmp +
     fsync + rename + dir fsync. Closes the shared-".tmp" rename race
     that happened when two fibers persisted the same journal path
     (downstream #9780 family). *)
  let buf = Buffer.create 4096 in
  List.iter
    (fun event ->
       Buffer.add_string buf (Yojson.Safe.to_string (event_to_json event));
       Buffer.add_char buf '\n')
    (events journal);
  match Fs_result.write_file path (Buffer.contents buf) with
  | Ok () -> Ok ()
  | Error e -> Error (Printf.sprintf "save_to_file: %s" (Error.to_string e))
;;

let max_journal_size = 50 * 1024 * 1024

let parse_lines lines =
  let rec read_lines acc count line_no = function
    | [] -> Ok { state = Atomic.make (acc, count); on_append = None }
    | line :: rest ->
      if String.trim line = ""
      then read_lines acc count (line_no + 1) rest
      else (
        let json =
          try Ok (Yojson.Safe.from_string line) with
          | Yojson.Json_error msg -> Error (Printf.sprintf "line %d: %s" line_no msg)
        in
        match json with
        | Error e -> Error e
        | Ok j ->
          (match event_of_json j with
           | Ok evt -> read_lines (evt :: acc) (count + 1) (line_no + 1) rest
           | Error e -> Error (Printf.sprintf "line %d: %s" line_no e)))
  in
  read_lines [] 0 1 lines
;;

let load_from_file ?fs path =
  match fs with
  | Some dir ->
    let file_path = Eio.Path.(dir / path) in
    if not (Eio.Path.is_file file_path)
    then Ok { state = Atomic.make ([], 0); on_append = None }
    else (
      try
        Eio.Path.with_open_in file_path (fun flow ->
          let contents =
            Eio.Buf_read.(of_flow flow ~max_size:max_journal_size |> take_all)
          in
          parse_lines (String.split_on_char '\n' contents))
      with
      | Eio.Io _ as e ->
        Error (Printf.sprintf "load_from_file: %s" (Printexc.to_string e))
      | exn -> Error (Printf.sprintf "load_from_file: %s" (Printexc.to_string exn)))
  | None ->
    if not (Sys.file_exists path)
    then Ok { state = Atomic.make ([], 0); on_append = None }
    else (
      try
        let ic = open_in path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () ->
             let rec read_lines acc count line_no =
               match input_line ic with
               | line ->
                 if String.trim line = ""
                 then read_lines acc count (line_no + 1)
                 else (
                   let json =
                     try Ok (Yojson.Safe.from_string line) with
                     | Yojson.Json_error msg ->
                       Error (Printf.sprintf "line %d: %s" line_no msg)
                   in
                   match json with
                   | Error e -> Error e
                   | Ok j ->
                     (match event_of_json j with
                      | Ok evt -> read_lines (evt :: acc) (count + 1) (line_no + 1)
                      | Error e -> Error (Printf.sprintf "line %d: %s" line_no e)))
               | exception End_of_file ->
                 Ok { state = Atomic.make (acc, count); on_append = None }
             in
             read_lines [] 0 1)
      with
      | Sys_error msg -> Error (Printf.sprintf "load_from_file: %s" msg))
;;
