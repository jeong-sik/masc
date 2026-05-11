module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Random = Stdlib.Random

(** Agent_stress -- RFC-0001 Phase 0.2 stress indicator recording.
    See {!agent_stress.mli}. *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

(* Closed sum mirroring [Agent_sdk.Error.sdk_error]'s 9 constructors.
   The sole producer ([Keeper_turn_cascade_budget.sdk_error_kind])
   pattern-matches the SDK tag, so the producer surface is bounded by
   the SDK type itself. *)
type error_kind =
  | Ek_api
  | Ek_agent
  | Ek_mcp
  | Ek_config
  | Ek_serialization
  | Ek_io
  | Ek_orchestration
  | Ek_a2a
  | Ek_internal

let error_kind_to_string = function
  | Ek_api -> "api"
  | Ek_agent -> "agent"
  | Ek_mcp -> "mcp"
  | Ek_config -> "config"
  | Ek_serialization -> "serialization"
  | Ek_io -> "io"
  | Ek_orchestration -> "orchestration"
  | Ek_a2a -> "a2a"
  | Ek_internal -> "internal"

let error_kind_of_string = function
  | "api" -> Some Ek_api
  | "agent" -> Some Ek_agent
  | "mcp" -> Some Ek_mcp
  | "config" -> Some Ek_config
  | "serialization" -> Some Ek_serialization
  | "io" -> Some Ek_io
  | "orchestration" -> Some Ek_orchestration
  | "a2a" -> Some Ek_a2a
  | "internal" -> Some Ek_internal
  | _ -> None

type stress_kind =
  | Failure_streak of int
  | Turn_failure of turn_failure
  | Fallback_approval
  | Timeout
  | Parse_degraded
  | Task_released

and turn_failure = {
  consecutive : int;
  threshold : int;
  counted_toward_crash : bool;
  recoverable : bool;
  error_kind : error_kind option;
}

type event = {
  agent_name : string;
  room_id : string;
  kind : stress_kind;
  timestamp : float;
}

(* ================================================================ *)
(* Serialization                                                    *)
(* ================================================================ *)

let stress_kind_to_json = function
  | Failure_streak n ->
    `Assoc [("type", `String "failure_streak"); ("count", `Int n)]
  | Turn_failure f ->
    let base = [
      ("type", `String "turn_failure");
      ("consecutive", `Int f.consecutive);
      ("threshold", `Int f.threshold);
      ("counted_toward_crash", `Bool f.counted_toward_crash);
      ("recoverable", `Bool f.recoverable);
    ] in
    let fields =
      match f.error_kind with
      | None -> base
      | Some kind -> base @ [("error_kind", `String (error_kind_to_string kind))]
    in
    `Assoc fields
  | Fallback_approval ->
    `Assoc [("type", `String "fallback_approval")]
  | Timeout ->
    `Assoc [("type", `String "timeout")]
  | Parse_degraded ->
    `Assoc [("type", `String "parse_degraded")]
  | Task_released ->
    `Assoc [("type", `String "task_released")]

let event_to_json (e : event) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String e.agent_name);
    ("room_id", `String e.room_id);
    ("kind", stress_kind_to_json e.kind);
    ("timestamp", `Float e.timestamp);
  ]

type board_agent = {
  agent : string;
  ctx_pressure : float option;
  queue_depth : int option;
  blocked_on : string option;
  ts : float option;
}

type board_acc = {
  agent : string;
  mutable budget_pressure : float;
  mutable ctx_pressure : float option;
  mutable queue_depth : int option;
  mutable blocked_on : string option;
  mutable ts : float;
  mutable saw_event : bool;
}

let clamp01 value =
  if value < 0.0 then 0.0 else if value > 1.0 then 1.0 else value

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String s) -> Some s
  | _ -> None

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (`Int n) -> Some n
  | Some (`Float f) -> Some (int_of_float f)
  | _ -> None

let float_field name fields =
  match List.assoc_opt name fields with
  | Some (`Float f) -> Some f
  | Some (`Int n) -> Some (float_of_int n)
  | _ -> None

let pressure_of_kind_fields fields =
  match string_field "type" fields with
  | Some "failure_streak" ->
      let count = int_field "count" fields |> Option.value ~default:0 in
      clamp01 (float_of_int count /. 3.0)
  | Some "turn_failure" ->
      let consecutive =
        int_field "consecutive" fields |> Option.value ~default:0
      in
      let threshold = int_field "threshold" fields |> Option.value ~default:3 in
      if threshold <= 0 then 0.0
      else clamp01 (float_of_int consecutive /. float_of_int threshold)
  | Some "timeout" -> 0.65
  | Some "task_released" -> 0.60
  | Some "parse_degraded" -> 0.40
  | Some "fallback_approval" -> 0.30
  | Some _ | None -> 0.0

let blocker_of_kind_fields fields =
  match string_field "type" fields with
  | Some ("failure_streak" | "turn_failure" | "timeout" | "task_released") as kind ->
      kind
  | Some _ | None -> None

let ensure_acc table agent =
  match Hashtbl.find_opt table agent with
  | Some acc -> acc
  | None ->
      let acc = {
        agent;
        budget_pressure = 0.0;
        ctx_pressure = None;
        queue_depth = None;
        blocked_on = None;
        ts = 0.0;
        saw_event = false;
      } in
      Hashtbl.add table agent acc;
      acc

let merge_board_agent table (agent : board_agent) =
  let name = String.trim agent.agent in
  if name <> "" then begin
    let acc = ensure_acc table name in
    acc.ctx_pressure <- agent.ctx_pressure;
    acc.queue_depth <- agent.queue_depth;
    (match agent.blocked_on with
     | Some value when String.trim value <> "" ->
         acc.blocked_on <- Some (String.trim value)
     | _ -> ());
    (match agent.ts with
     | Some ts when ts > acc.ts -> acc.ts <- ts
     | _ -> ())
  end

let merge_event table (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> (
      match string_field "agent_name" fields with
      | None | Some "" -> ()
      | Some agent ->
          let acc = ensure_acc table agent in
          acc.saw_event <- true;
          let ts = float_field "timestamp" fields |> Option.value ~default:0.0 in
          if ts > acc.ts then acc.ts <- ts;
          (match List.assoc_opt "kind" fields with
           | Some (`Assoc kind_fields) ->
               acc.budget_pressure <-
                 max acc.budget_pressure (pressure_of_kind_fields kind_fields);
               (match acc.blocked_on, blocker_of_kind_fields kind_fields with
                | None, Some blocker -> acc.blocked_on <- Some blocker
                | _ -> ())
           | _ -> ()))
  | _ -> ()

let board_row_to_json acc =
  let base = [
    ("agent", `String acc.agent);
    ("budget_pressure", `Float (clamp01 acc.budget_pressure));
    ("ctx_pressure",
     `Float (acc.ctx_pressure |> Option.value ~default:0.0 |> clamp01));
    ("queue_depth", `Int (acc.queue_depth |> Option.value ~default:0));
    ("ts", `Float acc.ts);
    ("ctx_pressure_source",
     `String (if Option.is_some acc.ctx_pressure then "keeper_meta" else "unavailable"));
    ("queue_depth_source",
     `String (if Option.is_some acc.queue_depth then "autonomous_queue_metric" else "unavailable"));
    ("budget_pressure_source",
     `String (if acc.saw_event then "agent_stress_events" else "unavailable"));
  ] in
  let fields =
    match acc.blocked_on with
    | None -> base
    | Some blocker -> base @ [("blocked_on", `String blocker)]
  in
  `Assoc fields

let board_rows_json ?(agents = []) events =
  let table = Hashtbl.create 16 in
  List.iter (merge_board_agent table) agents;
  List.iter (merge_event table) events;
  Hashtbl.fold (fun _ acc rows -> board_row_to_json acc :: rows) table []
  |> List.sort (fun left right ->
       match left, right with
       | `Assoc lf, `Assoc rf ->
           let la = string_field "agent" lf |> Option.value ~default:"" in
           let ra = string_field "agent" rf |> Option.value ~default:"" in
           String.compare la ra
       | _ -> 0)

let dashboard_feed_json ~limit ?(agents = []) events =
  `Assoc [
    ("limit", `Int limit);
    ("count", `Int (List.length events));
    ("events", `List events);
    ("agent_stress", `List (board_rows_json ~agents events));
  ]

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
  if not (Sys.file_exists dir) then
    try Sys.mkdir dir 0o755 with
    | Sys_error msg when String_util.contains_substring msg "exists" -> ()
    | Sys_error msg ->
      Log.warn ~ctx:"agent_stress" "cannot mkdir %s: %s" dir msg

let do_flush () =
  match !store_path_ref with
  | None -> ()
  | Some path ->
    if Queue.is_empty buffer then ()
    else begin
      ensure_dir path;
      match
        try Some (Stdlib.open_out_gen [Open_append; Open_creat; Open_text] 0o644 path)
        with Sys_error msg ->
          Log.warn ~ctx:"agent_stress" "cannot open %s: %s" path msg;
          None
      with
      | None ->
          Log.warn ~ctx:"agent_stress" "flush skipped: %d records remain buffered"
            (Queue.length buffer)
      | Some oc ->
        Stdlib.Fun.protect ~finally:(fun () -> Stdlib.close_out_noerr oc) (fun () ->
          Queue.iter (fun json ->
            Stdlib.output_string oc (Yojson.Safe.to_string json);
            Stdlib.output_char oc '\n'
          ) buffer);
        Queue.clear buffer
    end

let init ~base_path =
  Stdlib.Mutex.protect mu (fun () ->
    match !store_path_ref with
    | Some _ -> ()
    | None ->
      let masc_dir = Coord_utils.masc_dir_from_base_path ~base_path in
      let path = Filename.concat masc_dir "agent_stress.jsonl" in
      store_path_ref := Some path)

let record (e : event) =
  Stdlib.Mutex.protect mu (fun () ->
    let json = event_to_json e in
    Queue.add json buffer;
    if Queue.length buffer >= buffer_cap then
      do_flush ())

let flush () =
  Stdlib.Mutex.protect mu (fun () ->
    do_flush ())

let recent n =
  match !store_path_ref with
  | None -> []
  | Some path ->
    if not (Sys.file_exists path) then []
    else
      match Safe_ops.read_file_safe path with
      | Error msg ->
          Log.Misc.warn "[AgentStress] recent read_file_safe failed: %s" msg;
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
          try Some (Yojson.Safe.from_string line)
          with Yojson.Json_error msg ->
            Log.warn ~ctx:"agent_stress" "dropping malformed line: %s" msg;
            None)
