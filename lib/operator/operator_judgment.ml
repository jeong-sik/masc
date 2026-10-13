open Result.Syntax

type target_type =
  | Workspace

type surface =
  | Command_namespace
  | Intervene
[@@deriving enumerate]

module Confidence = struct
  type t = float

  let of_float value =
    if Float.is_finite value
       && Float.compare value 0.0 >= 0
       && Float.compare value 1.0 <= 0
    then Some value
    else None
end

type record = {
  judgment_id : string;
  surface : surface;
  target_type : target_type;
  target_id : string option;
  summary : string;
  confidence : Confidence.t;
  generated_at : string;
  generated_at_unix : float;
  fresh_until : string;
  fresh_until_unix : float;
  keeper_name : string;
  model_name : string option;
  runtime_name : string option;
  evidence_refs : string list;
  recommended_action : Yojson.Safe.t option;
  supersedes : string list;
  fallback_used : bool;
  disagreement_with_truth : bool;
}

let target_type_to_string = function
  | Workspace -> Operator_action_constants.workspace_target_type

let target_type_of_string = function
  | value ->
      (match Operator_action_constants.target_type_of_string value with
       | Some Operator_action_constants.Workspace -> Some Workspace
       | Some Operator_action_constants.Keeper
       | Some Operator_action_constants.Goal
       | None -> None)


let surface_to_string = function
  | Command_namespace -> "command.namespace"
  | Intervene -> "intervene"

let surface_of_string value =
  List.find_opt
    (fun surface -> String.equal (surface_to_string surface) value)
    all_of_surface

let operator_dir config =
  Filename.concat (Workspace.masc_dir config) "operator"

let judgments_path config =
  Filename.concat (operator_dir config) "judgments.jsonl"

let generate_id () =
  "judg-" ^ String.sub (Auth.generate_token ()) 0 20

let key_of ~surface ~target_type ~target_id =
  let target =
    match target_id with
    | Some value ->
        let trimmed = String.trim value in
        if trimmed <> "" then trimmed else "__workspace__"
    | None -> "__workspace__"
  in
  String.concat ":"
    [ surface_to_string surface; target_type_to_string target_type; target ]

let to_yojson (value : record) =
  `Assoc
    [
      ("judgment_id", `String value.judgment_id);
      ("surface", `String (surface_to_string value.surface));
      ("target_type", `String (target_type_to_string value.target_type));
      ("target_id", Json_util.option_to_yojson (fun v -> `String v) value.target_id);
      ("summary", `String value.summary);
      ("confidence", `Float (value.confidence :> float));
      ("generated_at", `String value.generated_at);
      ("generated_at_unix", `Float value.generated_at_unix);
      ("fresh_until", `String value.fresh_until);
      ("fresh_until_unix", `Float value.fresh_until_unix);
      ("keeper_name", `String value.keeper_name);
      ("model_name", Json_util.option_to_yojson (fun v -> `String v) value.model_name);
      ("runtime_name", Json_util.option_to_yojson (fun v -> `String v) value.runtime_name);
      ( "evidence_refs",
        `List (List.map (fun item -> `String item) value.evidence_refs) );
      ("recommended_action", Json_util.option_to_yojson (fun v -> v) value.recommended_action);
      ("supersedes", `List (List.map (fun item -> `String item) value.supersedes));
      ("fallback_used", `Bool value.fallback_used);
      ("disagreement_with_truth", `Bool value.disagreement_with_truth);
      ("provenance", `String "judgment");
    ]

let of_yojson json =
  try
    let* target_type =
      match Json_util.get_string json "target_type" with
      | Some value -> (
          match target_type_of_string value with
          | Some parsed -> Ok parsed
          | None -> Error "invalid target_type")
      | None -> Error "missing target_type"
    in
    let required_unix key =
      match Json_util.assoc_member_opt key json with
      | Some (`Float value) -> Ok value
      | Some (`Int value) -> Ok (float_of_int value)
      | Some _ -> Error ("invalid " ^ key)
      | None -> Error ("missing " ^ key)
    in
    let* generated_at_unix = required_unix "generated_at_unix" in
    let* fresh_until_unix = required_unix "fresh_until_unix" in
    (* [confidence] is the judge's own statement about a judgment an operator
       reads. An absent or malformed value is not 0.0 — that spelling would put
       "no opinion recorded" and "certain this is wrong" on the same number in
       the digest a human decides from. Every record this module writes carries
       the field, so a record without one is a corrupt record, not an old one. *)
    let* confidence =
      match Json_util.assoc_member_opt "confidence" json with
      | Some (`Float value) -> Ok value
      | Some (`Int value) -> Ok (float_of_int value)
      | Some _ -> Error "invalid confidence"
      | None -> Error "missing confidence"
    in
    let* confidence =
      Option.to_result ~none:"confidence out of range" (Confidence.of_float confidence)
    in
    (* The same holds for every other member: [record] writes all of them, so
       a record that lacks one, or carries the wrong JSON type, is corrupt.
       Reading it as [""], [false] or an empty list would put a judgment the
       judge never wrote into the digest, under a surface key ([""]) that
       matches nothing it was meant for. *)
    let required_string key =
      match Json_util.assoc_member_opt key json with
      | Some (`String value) -> Ok value
      | Some _ -> Error ("invalid " ^ key)
      | None -> Error ("missing " ^ key)
    in
    let optional_string key =
      match Json_util.assoc_member_opt key json with
      | None | Some `Null -> Ok None
      | Some (`String value) -> Ok (Some value)
      | Some _ -> Error ("invalid " ^ key)
    in
    let required_strings key =
      match Json_util.assoc_member_opt key json with
      | Some (`List items) ->
        let values =
          List.filter_map (function `String value -> Some value | _ -> None) items
        in
        if List.compare_lengths values items = 0 then Ok values
        else Error ("invalid " ^ key)
      | Some _ -> Error ("invalid " ^ key)
      | None -> Error ("missing " ^ key)
    in
    let required_bool key =
      match Json_util.assoc_member_opt key json with
      | Some (`Bool value) -> Ok value
      | Some _ -> Error ("invalid " ^ key)
      | None -> Error ("missing " ^ key)
    in
    let* judgment_id = required_string "judgment_id" in
    let* surface =
      let* raw = required_string "surface" in
      Option.to_result ~none:"invalid surface" (surface_of_string raw)
    in
    let* target_id = optional_string "target_id" in
    let* summary = required_string "summary" in
    let* generated_at = required_string "generated_at" in
    let* fresh_until = required_string "fresh_until" in
    let* keeper_name = required_string "keeper_name" in
    let* model_name = optional_string "model_name" in
    let* runtime_name = optional_string "runtime_name" in
    let* evidence_refs = required_strings "evidence_refs" in
    let* recommended_action =
      match Json_util.assoc_member_opt "recommended_action" json with
      | None | Some `Null -> Ok None
      | Some (`Assoc _ as value) -> Ok (Some value)
      | Some _ -> Error "invalid recommended_action"
    in
    let* supersedes = required_strings "supersedes" in
    let* fallback_used = required_bool "fallback_used" in
    let* disagreement_with_truth = required_bool "disagreement_with_truth" in
    Ok
      {
        judgment_id;
        surface;
        target_type;
        target_id;
        summary;
        confidence;
        generated_at;
        generated_at_unix;
        fresh_until;
        fresh_until_unix;
        keeper_name;
        model_name;
        runtime_name;
        evidence_refs;
        recommended_action;
        supersedes;
        fallback_used;
        disagreement_with_truth;
      }
  with Yojson.Safe.Util.Type_error (msg, _) | Failure msg -> Error msg

let generated_at_unix value =
  value.generated_at_unix

let fresh_until_unix value =
  value.fresh_until_unix

let is_fresh ?(now = Unix.gettimeofday ()) value =
  fresh_until_unix value > now

let load_all config =
  let path = judgments_path config in
  Fs_compat.fold_jsonl_lines
    ~init:[]
    ~f:(fun acc ~line_no json ->
      try
        match of_yojson json with
        | Ok value -> value :: acc
        | Error reason ->
          Log.Gate.warn "operator judgment parse: line %d: %s" line_no reason;
          acc
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Log.Gate.warn "operator judgment parse: %s" (Printexc.to_string exn);
        acc)
    path
  |> List.rev

let append config values =
  Fs_compat.mkdir_p (operator_dir config);
  let path = judgments_path config in
  List.iter
    (fun value ->
      Fs_compat.append_jsonl path (to_yojson value))
    values

let latest_by_key config =
  let table = Hashtbl.create 16 in
  load_all config
  |> List.iter (fun value ->
         let key =
           key_of ~surface:value.surface ~target_type:value.target_type
             ~target_id:value.target_id
         in
         match Hashtbl.find_opt table key with
         | Some current when generated_at_unix current >= generated_at_unix value -> ()
         | _ -> Hashtbl.replace table key value);
  table

let latest_active config ~surface ~target_type ~target_id =
  let table = latest_by_key config in
  Hashtbl.find_opt table (key_of ~surface ~target_type ~target_id)

let record config ~surface ~target_type ~target_id ~summary ~confidence
    ?model_name ?runtime_name ?recommended_action ?(evidence_refs = [])
    ?(fallback_used = false) ?(disagreement_with_truth = false) ~generated_at
    ~generated_at_unix ~fresh_until ~fresh_until_unix ~keeper_name () =
  let supersedes =
    match latest_active config ~surface ~target_type ~target_id with
    | Some value -> [ value.judgment_id ]
    | None -> []
  in
  let value =
    {
      judgment_id = generate_id ();
      surface;
      target_type;
      target_id;
      summary = String.trim summary;
      confidence;
      generated_at;
      generated_at_unix;
      fresh_until;
      fresh_until_unix;
      keeper_name;
      model_name;
      runtime_name;
      evidence_refs =
        evidence_refs
        |> List.filter_map (fun raw ->
               let trimmed = String.trim raw in
               if trimmed = "" then None else Some trimmed);
      recommended_action;
      supersedes;
      fallback_used;
      disagreement_with_truth;
    }
  in
  append config [ value ];
  value
