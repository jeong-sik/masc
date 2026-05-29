(* RFC-0203 Phase 2 (Dual-run) — measurement vehicle. See .mli for
   rationale of the closed-sum taxonomy. *)

type path =
  | Sidecar
  | Builtin

let string_of_path = function
  | Sidecar -> "sidecar"
  | Builtin -> "builtin"

type inbound_kind =
  | Ready
  | Message_create
  | Reaction_add
  | Ignored

let string_of_inbound_kind = function
  | Ready -> "ready"
  | Message_create -> "message_create"
  | Reaction_add -> "reaction_add"
  | Ignored -> "ignored"

type outbound_outcome =
  | Ok_message_id of string
  | Err_missing_token
  | Err_transient of string
  | Err_workflow of string
  | Err_runtime of string

let string_of_outbound_outcome = function
  | Ok_message_id _ -> "ok"
  | Err_missing_token -> "err_missing_token"
  | Err_transient _ -> "err_transient"
  | Err_workflow _ -> "err_workflow"
  | Err_runtime _ -> "err_runtime"

type counts =
  { ready : int
  ; message_create : int
  ; reaction_add : int
  ; ignored : int
  ; outbound_ok : int
  ; outbound_err_missing_token : int
  ; outbound_err_transient : int
  ; outbound_err_workflow : int
  ; outbound_err_runtime : int
  }

let zero_counts =
  { ready = 0
  ; message_create = 0
  ; reaction_add = 0
  ; ignored = 0
  ; outbound_ok = 0
  ; outbound_err_missing_token = 0
  ; outbound_err_transient = 0
  ; outbound_err_workflow = 0
  ; outbound_err_runtime = 0
  }

let counts_to_yojson c : Yojson.Safe.t =
  `Assoc
    [ "ready", `Int c.ready
    ; "message_create", `Int c.message_create
    ; "reaction_add", `Int c.reaction_add
    ; "ignored", `Int c.ignored
    ; "outbound_ok", `Int c.outbound_ok
    ; "outbound_err_missing_token", `Int c.outbound_err_missing_token
    ; "outbound_err_transient", `Int c.outbound_err_transient
    ; "outbound_err_workflow", `Int c.outbound_err_workflow
    ; "outbound_err_runtime", `Int c.outbound_err_runtime
    ]

(* ---------------------------------------------------------------- *)
(* Live counters                                                    *)
(* ---------------------------------------------------------------- *)

(* One [Atomic.t] per counter, per path. We pre-allocate the 18
   atomics at load time and look them up by path×bucket. Concurrent
   fibers from the gateway reader, the heartbeat fiber, and the
   outbound dispatcher all hit these — Atomic.t makes the increments
   data-race-free without a mutex. *)

type bucket =
  | B_ready
  | B_message_create
  | B_reaction_add
  | B_ignored
  | B_outbound_ok
  | B_outbound_err_missing_token
  | B_outbound_err_transient
  | B_outbound_err_workflow
  | B_outbound_err_runtime

let counters_for_path : path -> (bucket * int Atomic.t) list =
  let make () =
    [ B_ready, Atomic.make 0
    ; B_message_create, Atomic.make 0
    ; B_reaction_add, Atomic.make 0
    ; B_ignored, Atomic.make 0
    ; B_outbound_ok, Atomic.make 0
    ; B_outbound_err_missing_token, Atomic.make 0
    ; B_outbound_err_transient, Atomic.make 0
    ; B_outbound_err_workflow, Atomic.make 0
    ; B_outbound_err_runtime, Atomic.make 0
    ]
  in
  let sidecar = make () in
  let builtin = make () in
  function
  | Sidecar -> sidecar
  | Builtin -> builtin

let counter_of ~path bucket =
  List.assoc bucket (counters_for_path path)

let bucket_of_inbound = function
  | Ready -> B_ready
  | Message_create -> B_message_create
  | Reaction_add -> B_reaction_add
  | Ignored -> B_ignored

let bucket_of_outbound = function
  | Ok_message_id _ -> B_outbound_ok
  | Err_missing_token -> B_outbound_err_missing_token
  | Err_transient _ -> B_outbound_err_transient
  | Err_workflow _ -> B_outbound_err_workflow
  | Err_runtime _ -> B_outbound_err_runtime

let incr ~path bucket =
  let c = counter_of ~path bucket in
  ignore (Atomic.fetch_and_add c 1)

(* ---------------------------------------------------------------- *)
(* Audit JSONL                                                      *)
(* ---------------------------------------------------------------- *)

let default_audit_path = ".gate/runtime/discord/traffic_audit.jsonl"

let audit_path () =
  Channel_gate_discord_names.configured_write_path
    "MASC_DISCORD_TRAFFIC_AUDIT_PATH"
    ~default:default_audit_path

let iso8601_now () =
  Gate_time_util.iso8601_of_unix (Unix.gettimeofday ())

(* Best-effort append: any IO failure is logged and swallowed. The
   live counters remain the load-bearing measurement; the JSONL is
   for offline cross-path diff. *)
let append_audit_line (json : Yojson.Safe.t) =
  let path = audit_path () in
  let dir = Filename.dirname path in
  match
    (try Fs_compat.mkdir_p dir; Ok () with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> Error (Printexc.to_string exn))
  with
  | Error _ -> ()
  | Ok () ->
    (try
       let oc =
         open_out_gen
           [ Open_creat; Open_wronly; Open_append; Open_binary ]
           0o644
           path
       in
       Fun.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () ->
           output_string oc (Yojson.Safe.to_string json);
           output_char oc '\n';
           flush oc)
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | _ -> ())

let inbound_audit_json ~path kind : Yojson.Safe.t =
  `Assoc
    [ "timestamp", `String (iso8601_now ())
    ; "direction", `String "inbound"
    ; "path", `String (string_of_path path)
    ; "kind", `String (string_of_inbound_kind kind)
    ]

let outbound_audit_json ~path outcome : Yojson.Safe.t =
  let detail =
    match outcome with
    | Ok_message_id id -> [ "message_id", `String id ]
    | Err_missing_token -> []
    | Err_transient msg
    | Err_workflow msg
    | Err_runtime msg -> [ "message", `String msg ]
  in
  `Assoc
    ([ "timestamp", `String (iso8601_now ())
     ; "direction", `String "outbound"
     ; "path", `String (string_of_path path)
     ; "outcome", `String (string_of_outbound_outcome outcome)
     ]
     @ detail)

(* ---------------------------------------------------------------- *)
(* Public recorders                                                 *)
(* ---------------------------------------------------------------- *)

let record_inbound ~path kind =
  incr ~path (bucket_of_inbound kind);
  append_audit_line (inbound_audit_json ~path kind)

let record_outbound ~path outcome =
  incr ~path (bucket_of_outbound outcome);
  append_audit_line (outbound_audit_json ~path outcome)

(* ---------------------------------------------------------------- *)
(* Snapshot                                                         *)
(* ---------------------------------------------------------------- *)

let snapshot ~path =
  let read b = Atomic.get (counter_of ~path b) in
  { ready = read B_ready
  ; message_create = read B_message_create
  ; reaction_add = read B_reaction_add
  ; ignored = read B_ignored
  ; outbound_ok = read B_outbound_ok
  ; outbound_err_missing_token = read B_outbound_err_missing_token
  ; outbound_err_transient = read B_outbound_err_transient
  ; outbound_err_workflow = read B_outbound_err_workflow
  ; outbound_err_runtime = read B_outbound_err_runtime
  }

let reset_for_test () =
  let zero path =
    List.iter (fun (_, a) -> Atomic.set a 0) (counters_for_path path)
  in
  zero Sidecar;
  zero Builtin
