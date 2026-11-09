(** Run metrics — the quantitative record one agent run can carry.

    [metric_value] is a closed variant. [run_metrics] groups the metrics and
    {!Harness.verdict}s of a run and serializes to JSON for the trajectory
    record. *)

(* ── Metric value ─────────────────────────────────────────────── *)

type metric_value =
  | Int_val of int
  | Float_val of float
  | Bool_val of bool
  | String_val of string

let metric_value_to_yojson = function
  | Int_val i -> `Int i
  | Float_val f -> `Float f
  | Bool_val b -> `Bool b
  | String_val s -> `String s
;;

(* ── Metric ───────────────────────────────────────────────────── *)

type metric =
  { name : string
  ; value : metric_value
  ; unit_ : string option
  ; tags : (string * string) list
  }

let metric_to_yojson m =
  let base = [ "name", `String m.name; "value", metric_value_to_yojson m.value ] in
  let unit_part =
    match m.unit_ with
    | Some u -> [ "unit", `String u ]
    | None -> []
  in
  let tags_part =
    match m.tags with
    | [] -> []
    | tags -> [ "tags", Util.json_of_string_pairs tags ]
  in
  `Assoc (base @ unit_part @ tags_part)
;;

(* ── Run metrics ──────────────────────────────────────────────── *)

type run_metrics =
  { run_id : string
  ; agent_name : string
  ; timestamp : float
  ; metrics : metric list
  ; harness_verdicts : Harness.verdict list
  }

let run_metrics_to_yojson rm =
  let verdicts_json =
    `List
      (List.map
         (fun (v : Harness.verdict) ->
            `Assoc
              [ "passed", `Bool v.passed
              ; ( "score"
                , match v.score with
                  | Some s -> `Float s
                  | None -> `Null )
              ; "evidence", Util.json_of_string_list v.evidence
              ; ( "detail"
                , match v.detail with
                  | Some d -> `String d
                  | None -> `Null )
              ])
         rm.harness_verdicts)
  in
  `Assoc
    [ "run_id", `String rm.run_id
    ; "agent_name", `String rm.agent_name
    ; "timestamp", `Float rm.timestamp
    ; "metrics", `List (List.map metric_to_yojson rm.metrics)
    ; "harness_verdicts", verdicts_json
    ]
;;
