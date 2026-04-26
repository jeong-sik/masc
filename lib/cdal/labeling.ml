(** Labeling — CDAL labeling protocol v0 types and metrics.

    @since CDAL Labeling Protocol v0 *)

(* ================================================================ *)
(* Core types                                                        *)
(* ================================================================ *)

type label =
  | Supported
  | Unsupported
  | Ambiguous
  | Drift

type labeled_verdict =
  { verdict : Cdal_types.contract_verdict
  ; label : label
  ; labeler : string
  ; note : string option
  ; labeled_at : string
  }

type confusion_summary =
  { supported : int
  ; unsupported : int
  ; ambiguous : int
  ; drift : int
  }

type output_contract =
  { workload_name : string
  ; protocol_version : string
  ; judge_protocol_version : string
  ; label_owner : string
  ; metric_owner : string
  ; confusion : confusion_summary
  ; claim_coverage : float
  ; precision_strict : float
  ; precision_lenient : float
  ; drift_note : string
  }

(* ================================================================ *)
(* String conversions                                                *)
(* ================================================================ *)

let label_to_string = function
  | Supported -> "supported"
  | Unsupported -> "unsupported"
  | Ambiguous -> "ambiguous"
  | Drift -> "drift"
;;

let label_of_string = function
  | "supported" -> Ok Supported
  | "unsupported" -> Ok Unsupported
  | "ambiguous" -> Ok Ambiguous
  | "drift" -> Ok Drift
  | s -> Error (Printf.sprintf "unknown label: %s" s)
;;

(* ================================================================ *)
(* Metrics — protocol Section 3                                      *)
(* ================================================================ *)

let compute_confusion (verdicts : labeled_verdict list) =
  List.fold_left
    (fun acc v ->
       match v.label with
       | Supported -> { acc with supported = acc.supported + 1 }
       | Unsupported -> { acc with unsupported = acc.unsupported + 1 }
       | Ambiguous -> { acc with ambiguous = acc.ambiguous + 1 }
       | Drift -> { acc with drift = acc.drift + 1 })
    { supported = 0; unsupported = 0; ambiguous = 0; drift = 0 }
    verdicts
;;

let compute_precision_strict (c : confusion_summary) =
  let denom = c.supported + c.unsupported + c.ambiguous in
  if denom = 0 then 0.0 else float_of_int c.supported /. float_of_int denom
;;

let compute_precision_lenient (c : confusion_summary) =
  let denom = c.supported + c.unsupported in
  if denom = 0 then 0.0 else float_of_int c.supported /. float_of_int denom
;;

let compute_claim_coverage ~labeled ~total =
  if total = 0 then 0.0 else float_of_int labeled /. float_of_int total
;;

let build_output_contract
      ~workload_name
      ~protocol_version
      ~judge_protocol_version
      ~label_owner
      ~metric_owner
      ~total_claims
      ~drift_note
      verdicts
  =
  let confusion = compute_confusion verdicts in
  let labeled_non_drift =
    confusion.supported + confusion.unsupported + confusion.ambiguous
  in
  { workload_name
  ; protocol_version
  ; judge_protocol_version
  ; label_owner
  ; metric_owner
  ; confusion
  ; claim_coverage = compute_claim_coverage ~labeled:labeled_non_drift ~total:total_claims
  ; precision_strict = compute_precision_strict confusion
  ; precision_lenient = compute_precision_lenient confusion
  ; drift_note
  }
;;

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let label_to_json l = `String (label_to_string l)

let labeled_verdict_to_json v =
  `Assoc
    [ "verdict", Cdal_types.contract_verdict_to_json v.verdict
    ; "label", label_to_json v.label
    ; "labeler", `String v.labeler
    ; ( "note"
      , match v.note with
        | Some n -> `String n
        | None -> `Null )
    ; "labeled_at", `String v.labeled_at
    ]
;;

let labeled_verdict_of_json = function
  | `Assoc fields ->
    let open Result in
    (match
       ( List.assoc_opt "verdict" fields
       , List.assoc_opt "label" fields
       , List.assoc_opt "labeler" fields
       , List.assoc_opt "labeled_at" fields )
     with
     | ( Some verdict_json
       , Some (`String label_str)
       , Some (`String labeler)
       , Some (`String labeled_at) ) ->
       (match
          Cdal_types.contract_verdict_of_json verdict_json, label_of_string label_str
        with
        | Ok verdict, Ok label ->
          let note =
            match List.assoc_opt "note" fields with
            | Some (`String n) -> Some n
            | _ -> None
          in
          Ok { verdict; label; labeler; note; labeled_at }
        | Error e, _ -> Error (Printf.sprintf "verdict: %s" e)
        | _, Error e -> Error (Printf.sprintf "label: %s" e))
     | _ -> Error "missing or invalid fields in labeled_verdict")
  | _ -> Error "labeled_verdict: expected JSON object"
;;

let confusion_summary_to_json c =
  `Assoc
    [ "supported", `Int c.supported
    ; "unsupported", `Int c.unsupported
    ; "ambiguous", `Int c.ambiguous
    ; "drift", `Int c.drift
    ]
;;

let output_contract_to_json oc =
  `Assoc
    [ "workload_name", `String oc.workload_name
    ; "protocol_version", `String oc.protocol_version
    ; "judge_protocol_version", `String oc.judge_protocol_version
    ; "label_owner", `String oc.label_owner
    ; "metric_owner", `String oc.metric_owner
    ; "confusion", confusion_summary_to_json oc.confusion
    ; "claim_coverage", `Float oc.claim_coverage
    ; "precision_strict", `Float oc.precision_strict
    ; "precision_lenient", `Float oc.precision_lenient
    ; "drift_note", `String oc.drift_note
    ]
;;
