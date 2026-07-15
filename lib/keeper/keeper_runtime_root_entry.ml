type keeper_artifact =
  | Metadata
  | Metrics_log
  | Memory_log
  | Generation_index_log
  | Policy_log
  | Decision_log
  | Feedback_log
  | Tla_trace_log

type global_artifact =
  | Alerts_log
  | Alerts_retry_log
  | Alerts_deadletter_log

type t =
  | Keeper of
      { keeper_name : string
      ; artifact : keeper_artifact
      ; rotation : int option
      }
  | Global of
      { artifact : global_artifact
      ; rotation : int option
      }

let keeper_suffix = function
  | Metadata -> ".json"
  | Metrics_log -> ".metrics.jsonl"
  | Memory_log -> ".memory.jsonl"
  | Generation_index_log -> ".generation_index.jsonl"
  | Policy_log -> ".policy.jsonl"
  | Decision_log -> ".decisions.jsonl"
  | Feedback_log -> ".feedback.jsonl"
  | Tla_trace_log -> ".tla-trace.jsonl"
;;

let keeper_basename ~keeper_name artifact = keeper_name ^ keeper_suffix artifact

let global_basename = function
  | Alerts_log -> "_alerts.jsonl"
  | Alerts_retry_log -> "_alerts.retry.jsonl"
  | Alerts_deadletter_log -> "_alerts.deadletter.jsonl"
;;

let basename = function
  | Keeper { keeper_name; artifact; rotation } ->
    let base = keeper_basename ~keeper_name artifact in
    Option.fold ~none:base ~some:(fun rotation -> base ^ "." ^ string_of_int rotation) rotation
  | Global { artifact; rotation } ->
    let base = global_basename artifact in
    Option.fold ~none:base ~some:(fun rotation -> base ^ "." ^ string_of_int rotation) rotation
;;

type descriptor =
  | Keeper_descriptor of
      { artifact : keeper_artifact
      ; rotatable : bool
      }
  | Global_descriptor of
      { artifact : global_artifact
      ; rotatable : bool
      }

(* Longest Keeper suffixes precede [.json], preserving dotted Keeper names
   while keeping classification total and deterministic. *)
let descriptors =
  [ Keeper_descriptor { artifact = Generation_index_log; rotatable = true }
  ; Global_descriptor { artifact = Alerts_deadletter_log; rotatable = true }
  ; Global_descriptor { artifact = Alerts_retry_log; rotatable = true }
  ; Keeper_descriptor { artifact = Decision_log; rotatable = true }
  ; Keeper_descriptor { artifact = Feedback_log; rotatable = true }
  ; Keeper_descriptor { artifact = Memory_log; rotatable = true }
  ; Keeper_descriptor { artifact = Metrics_log; rotatable = true }
  ; Keeper_descriptor { artifact = Policy_log; rotatable = true }
  ; Keeper_descriptor { artifact = Tla_trace_log; rotatable = true }
  ; Global_descriptor { artifact = Alerts_log; rotatable = true }
  ; Keeper_descriptor { artifact = Metadata; rotatable = false }
  ]
;;

let positive_decimal value =
  not (String.equal value "")
  && String.for_all (function '0' .. '9' -> true | _ -> false) value
  && match int_of_string_opt value with
     | Some value -> value > 0
     | None -> false
;;

let split_rotation basename =
  match String.rindex_opt basename '.' with
  | None -> basename, None
  | Some separator ->
    let suffix_start = separator + 1 in
    let suffix_length = String.length basename - suffix_start in
    let candidate = String.sub basename suffix_start suffix_length in
    if positive_decimal candidate
    then
      ( String.sub basename 0 separator
      , Some (int_of_string candidate) )
    else basename, None
;;

let strip_suffix value suffix =
  if String.ends_with ~suffix value
  then
    Some (String.sub value 0 (String.length value - String.length suffix))
  else None
;;

let classify_basename observed_basename =
  let unrotated_basename, rotation = split_rotation observed_basename in
  let candidate_if_canonical candidate =
    if String.equal (basename candidate) observed_basename
    then Some candidate
    else None
  in
  let rec classify candidates = function
    | [] -> List.rev candidates
    | Keeper_descriptor { artifact; rotatable } :: rest ->
      (match strip_suffix unrotated_basename (keeper_suffix artifact) with
       | Some keeper_name
         when (Option.is_none rotation || rotatable)
              && Safe_identifier.is_portable_name keeper_name ->
         let candidate = Keeper { keeper_name; artifact; rotation } in
         let candidates =
           Option.fold
             ~none:candidates
             ~some:(fun candidate -> candidate :: candidates)
             (candidate_if_canonical candidate)
         in
         classify candidates rest
       | Some _ | None -> classify candidates rest)
    | Global_descriptor { artifact; rotatable } :: rest ->
      if
        String.equal unrotated_basename (global_basename artifact)
        && (Option.is_none rotation || rotatable)
      then
        let candidate = Global { artifact; rotation } in
        let candidates =
          Option.fold
            ~none:candidates
            ~some:(fun candidate -> candidate :: candidates)
            (candidate_if_canonical candidate)
        in
        classify candidates rest
      else classify candidates rest
  in
  classify [] descriptors
;;

let metadata_keeper_name observed_basename =
  classify_basename observed_basename
  |> List.find_map (function
    | Keeper { keeper_name; artifact = Metadata; rotation = None } -> Some keeper_name
    | Keeper _ | Global _ -> None)
;;
