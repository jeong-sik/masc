(* The loop guard's seed from checkpoint history stops where the guard has
   already judged. See the .mli. *)

type error = Invalid_record of string

let error_to_string = function
  | Invalid_record detail -> "keeper repetition judged record: " ^ detail
;;

let context_key = "keeper_repetition_judged"

let decode = function
  | `Assoc fields ->
    (match List.assoc_opt "history_pairs" fields with
     | Some (`Int pairs) when pairs >= 0 -> Ok pairs
     | Some (`Int pairs) ->
       Error (Invalid_record (Printf.sprintf "history_pairs is negative: %d" pairs))
     | Some _ -> Error (Invalid_record "history_pairs is not an integer")
     | None -> Error (Invalid_record "history_pairs is missing"))
  | _ -> Error (Invalid_record "not an object")
;;

let encode pairs = `Assoc [ "history_pairs", `Int pairs ]

let held context =
  match Agent_core.Context.get_scoped context Agent_core.Context.Session context_key with
  | None -> Ok 0
  | Some json -> decode json
;;

let record context pairs =
  Agent_core.Context.set_scoped context Agent_core.Context.Session context_key (encode pairs)
;;

(* The larger of the two, and only ever written up: the durable one is what
   an AGENT_CORE checkpoint carried, the live one what a yield on a lane
   that persists no checkpoint recorded into the loop-lived context since.
   Pairs are only appended, so the larger is the later fact. *)
let restore ~source ~target =
  match held source, held target with
  | Error _ as error, _ -> error
  | Ok _, (Error _ as error) -> error
  | Ok durable, Ok live ->
    let pairs = max durable live in
    if pairs > live then record target pairs;
    Ok pairs
;;

(* The history pair count the next setup will see for this run's calls:
   what the seeder counts is a ToolUse answered by a ToolResult whose
   digest succeeded, and the live hook records exactly those calls with
   both fingerprints present. *)
let pairs_judged_by ~history_pairs_at_setup (tool_calls : Keeper_agent_result.tool_call_detail list) =
  let fingerprinted =
    List.length
      (List.filter
         (fun (call : Keeper_agent_result.tool_call_detail) ->
           Option.is_some call.input_fingerprint && Option.is_some call.output_fingerprint)
         tool_calls)
  in
  history_pairs_at_setup + fingerprinted
;;

let seed_beyond ~judged pairs =
  let total = List.length pairs in
  let keep = max 0 (total - judged) in
  List.filteri (fun index _ -> index < keep) pairs
;;
