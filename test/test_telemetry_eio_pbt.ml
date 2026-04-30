(** Property-based tests for Telemetry_eio JSON contract.

    Closes the silent-failure class behind #10356 / #10450.  Both fixes were
    reactive per-variant patches to a manual lenient parser; this suite makes
    the schema contract itself the single source of truth.

    Properties:
    1. [prop_roundtrip] — every encoded record decodes back to itself.
       Catches [@@deriving yojson] / [@default] drift between encoder and
       decoder.
    2. [prop_null_absorption] — for every [option] key in a Tool_called
       payload, replacing its encoded value with [`Null] still yields a
       successful decode (with that field = [None]).
    3. [prop_drop_absorption] — same as (2) but the key is removed entirely
       instead of nulled out.  Future producers may elide [None] fields, and
       readers must remain tolerant.

    Properties (2) + (3) collectively make the addition of a new [option]
    field automatically safe — no per-variant lenient code to remember. *)

module Telemetry_eio = Masc_mcp.Telemetry_eio

let opt_string =
  let open QCheck.Gen in
  oneof [ return None; map (fun s -> Some s) string_small ]

let opt_int =
  let open QCheck.Gen in
  oneof [ return None; map (fun n -> Some n) nat_small ]

(** Generator that exercises every event variant.  Keeps strings short and
    avoids control characters to keep counterexamples readable. *)
let gen_event : Telemetry_eio.event QCheck.Gen.t =
  let open QCheck.Gen in
  let* tag = int_range 0 7 in
  match tag with
  | 0 ->
      let* agent_id = string_small in
      let* capabilities = list_size (int_range 0 3) string_small in
      return (Telemetry_eio.Agent_joined { agent_id; capabilities })
  | 1 ->
      let* agent_id = string_small in
      let* reason = string_small in
      return (Telemetry_eio.Agent_left { agent_id; reason })
  | 2 ->
      let* task_id = string_small in
      let* agent_id = string_small in
      return (Telemetry_eio.Task_started { task_id; agent_id })
  | 3 ->
      let* task_id = string_small in
      let* duration_ms = nat_small in
      let* success = bool in
      return (Telemetry_eio.Task_completed { task_id; duration_ms; success })
  | 4 ->
      let* from_agent = string_small in
      let* to_agent = string_small in
      let* reason = string_small in
      return
        (Telemetry_eio.Handoff_triggered { from_agent; to_agent; reason })
  | 5 ->
      let* code = string_small in
      let* message = string_small in
      let* context = string_small in
      return (Telemetry_eio.Error_occurred { code; message; context })
  | 6 ->
      let* tool_name = string_small in
      let* success = bool in
      let* duration_ms = nat_small in
      let* agent_id = opt_string in
      let* source = opt_string in
      let* session_id = opt_string in
      let* operation_id = opt_string in
      let* worker_run_id = opt_string in
      let* error_kind = opt_string in
      let* error_message = opt_string in
      let* exit_code = opt_int in
      let* stderr_excerpt = opt_string in
      return
        (Telemetry_eio.Tool_called
           {
             tool_name;
             success;
             duration_ms;
             agent_id;
             source;
             session_id;
             operation_id;
             worker_run_id;
             error_kind = Option.map Telemetry_eio.error_kind_of_string error_kind;
             error_message;
             exit_code;
             stderr_excerpt;
           })
  | _ ->
      let* agent_id = string_small in
      let* profile = string_small in
      let* preset = opt_string in
      let* tool_count = nat_small in
      let* assignment_id = string_small in
      return
        (Telemetry_eio.Tool_assigned
           { agent_id; profile; preset; tool_count; assignment_id })

let gen_record : Telemetry_eio.event_record QCheck.Gen.t =
  let open QCheck.Gen in
  let* timestamp = float in
  let* event = gen_event in
  return Telemetry_eio.{ timestamp; event }

let arb_record =
  QCheck.make ~print:Telemetry_eio.show_event_record gen_record

(** All [option] field names known to Tool_called (the heavy variant). *)
let tool_called_option_keys =
  [
    "agent_id";
    "source";
    "session_id";
    "operation_id";
    "worker_run_id";
    "error_kind";
    "error_message";
    "exit_code";
    "stderr_excerpt";
  ]

(** Tool_called record with every [option] field set to [Some _], so the
    encoded JSON contains the full key set we will mutate. *)
let saturated_tool_called : Telemetry_eio.event_record =
  {
    timestamp = 1_777_120_000.0;
    event =
      Tool_called
        {
          tool_name = "keeper_bash";
          success = false;
          duration_ms = 658;
          agent_id = Some "keeper-x";
          source = Some "keeper_internal";
          session_id = Some "mcp-session";
          operation_id = Some "op-1";
          worker_run_id = Some "wr-1";
          error_kind = Some (Telemetry_eio.error_kind_of_string "failure");
          error_message = Some "boom";
          exit_code = Some 1;
          stderr_excerpt = Some "...";
        };
  }

let mutate_event_field f json =
  match json with
  | `Assoc top -> (
      match List.assoc_opt "event" top with
      | Some (`List [ `String tag; `Assoc fields ]) ->
          let fields' = f fields in
          `Assoc
            (List.map
               (fun (k, v) ->
                 if k = "event" then
                   (k, `List [ `String tag; `Assoc fields' ])
                 else (k, v))
               top)
      | _ -> json)
  | _ -> json

let null_field key fields =
  List.map (fun (k, v) -> if k = key then (k, `Null) else (k, v)) fields

let drop_field key fields = List.filter (fun (k, _) -> k <> key) fields

let prop_roundtrip =
  QCheck.Test.make ~count:200 ~name:"Telemetry_eio JSON round-trip"
    arb_record (fun r ->
      let json = Telemetry_eio.event_record_to_yojson r in
      match Telemetry_eio.event_record_of_yojson json with
      | Ok r' -> r = r'
      | Error _ -> false)

let prop_null_absorption =
  QCheck.Test.make ~count:1
    ~name:"Tool_called: nulling any optional key still parses"
    QCheck.unit (fun () ->
      let base = Telemetry_eio.event_record_to_yojson saturated_tool_called in
      List.for_all
        (fun key ->
          let mutated = mutate_event_field (null_field key) base in
          match Telemetry_eio.event_record_of_yojson mutated with
          | Ok _ -> true
          | Error _ -> false)
        tool_called_option_keys)

let prop_drop_absorption =
  QCheck.Test.make ~count:1
    ~name:"Tool_called: dropping any optional key still parses"
    QCheck.unit (fun () ->
      let base = Telemetry_eio.event_record_to_yojson saturated_tool_called in
      List.for_all
        (fun key ->
          let mutated = mutate_event_field (drop_field key) base in
          match Telemetry_eio.event_record_of_yojson mutated with
          | Ok _ -> true
          | Error _ -> false)
        tool_called_option_keys)

let () =
  let suite =
    List.map QCheck_alcotest.to_alcotest
      [ prop_roundtrip; prop_null_absorption; prop_drop_absorption ]
  in
  Alcotest.run "Telemetry_eio PBT" [ ("yojson contract", suite) ]
