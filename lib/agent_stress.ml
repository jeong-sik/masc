(** Agent_stress -- RFC-0001 Phase 0.2 stress indicator recording.
    See {!agent_stress.mli}. *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type stress_kind =
  | Failure_streak of int
  | Turn_failure of turn_failure
  | Fallback_approval
  | Timeout
  | Parse_degraded
  | Task_released

and turn_failure =
  { consecutive : int
  ; threshold : int
  ; counted_toward_crash : bool
  ; recoverable : bool
  ; error_kind : string option
  }

type event =
  { agent_name : string
  ; room_id : string
  ; kind : stress_kind
  ; timestamp : float
  }

(* ================================================================ *)
(* Serialization                                                    *)
(* ================================================================ *)

let stress_kind_to_json = function
  | Failure_streak n -> `Assoc [ "type", `String "failure_streak"; "count", `Int n ]
  | Turn_failure f ->
    let base =
      [ "type", `String "turn_failure"
      ; "consecutive", `Int f.consecutive
      ; "threshold", `Int f.threshold
      ; "counted_toward_crash", `Bool f.counted_toward_crash
      ; "recoverable", `Bool f.recoverable
      ]
    in
    let fields =
      match f.error_kind with
      | None -> base
      | Some kind -> base @ [ "error_kind", `String kind ]
    in
    `Assoc fields
  | Fallback_approval -> `Assoc [ "type", `String "fallback_approval" ]
  | Timeout -> `Assoc [ "type", `String "timeout" ]
  | Parse_degraded -> `Assoc [ "type", `String "parse_degraded" ]
  | Task_released -> `Assoc [ "type", `String "task_released" ]
;;

let event_to_json (e : event) : Yojson.Safe.t =
  `Assoc
    [ "agent_name", `String e.agent_name
    ; "room_id", `String e.room_id
    ; "kind", stress_kind_to_json e.kind
    ; "timestamp", `Float e.timestamp
    ]
;;

(* ================================================================ *)
(* Storage (same pattern as Heuristic_metrics)                      *)
(* ================================================================ *)

let store_path_ref : string option ref = ref None

(* Stdlib.Mutex: record is non-yielding, callers may run outside Eio context *)
let mu = Stdlib.Mutex.create ()
let buffer : Yojson.Safe.t Queue.t = Queue.create ()
let buffer_cap = 64

let ensure_dir path =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir)
  then (
    try Sys.mkdir dir 0o755 with
    | Sys_error msg when String_util.contains_substring msg "exists" -> ()
    | Sys_error msg -> Log.warn ~ctx:"agent_stress" "cannot mkdir %s: %s" dir msg)
;;

let do_flush () =
  match !store_path_ref with
  | None -> ()
  | Some path ->
    if Queue.is_empty buffer
    then ()
    else (
      ensure_dir path;
      match
        try Some (open_out_gen [ Open_append; Open_creat; Open_text ] 0o644 path) with
        | Sys_error msg ->
          Log.warn ~ctx:"agent_stress" "cannot open %s: %s" path msg;
          None
      with
      | None ->
        Log.warn
          ~ctx:"agent_stress"
          "flush skipped: %d records remain buffered"
          (Queue.length buffer)
      | Some oc ->
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () ->
             Queue.iter
               (fun json ->
                  output_string oc (Yojson.Safe.to_string json);
                  output_char oc '\n')
               buffer);
        Queue.clear buffer)
;;

let init ~base_path =
  Stdlib.Mutex.protect mu (fun () ->
    match !store_path_ref with
    | Some _ -> ()
    | None ->
      let masc_dir = Coord_utils.masc_dir_from_base_path ~base_path in
      let path = Filename.concat masc_dir "agent_stress.jsonl" in
      store_path_ref := Some path)
;;

let record (e : event) =
  Stdlib.Mutex.protect mu (fun () ->
    let json = event_to_json e in
    Queue.add json buffer;
    if Queue.length buffer >= buffer_cap then do_flush ())
;;

let flush () = Stdlib.Mutex.protect mu (fun () -> do_flush ())

let recent n =
  match !store_path_ref with
  | None -> []
  | Some path ->
    if not (Sys.file_exists path)
    then []
    else (
      match Safe_ops.read_file_safe path with
      | Error msg ->
        Eio.traceln "[AgentStress] recent read_file_safe failed: %s" msg;
        []
      | Ok content ->
        let lines =
          String.split_on_char '\n' content
          |> List.filter (fun l -> String.length (String.trim l) > 0)
        in
        let total = List.length lines in
        let to_skip = max 0 (total - n) in
        let rec drop k = function
          | [] -> []
          | _ :: rest when k > 0 -> drop (k - 1) rest
          | xs -> xs
        in
        drop to_skip lines
        |> List.filter_map (fun line ->
          try Some (Yojson.Safe.from_string line) with
          | Yojson.Json_error msg ->
            Log.warn ~ctx:"agent_stress" "dropping malformed line: %s" msg;
            None))
;;
