open Result.Syntax

type target_type =
  | Workspace

type record = {
  judgment_id : string;
  surface : string;
  target_type : target_type;
  target_id : string option;
  status : string;
  summary : string;
  confidence : float;
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
  String.concat ":" [ surface; target_type_to_string target_type; target ]

let to_yojson (value : record) =
  `Assoc
    [
      ("judgment_id", `String value.judgment_id);
      ("surface", `String value.surface);
      ("target_type", `String (target_type_to_string value.target_type));
      ("target_id", Json_util.option_to_yojson (fun v -> `String v) value.target_id);
      ("status", `String value.status);
      ("summary", `String value.summary);
      ("confidence", `Float value.confidence);
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
    Ok
      {
        judgment_id = (match Json_util.assoc_member_opt "judgment_id" json with Some (`String s) -> s | _ -> "");
        surface = (match Json_util.assoc_member_opt "surface" json with Some (`String s) -> s | _ -> "");
        target_type;
        target_id = Json_util.get_string json "target_id";
        status =
          Json_util.get_string json "status"
          |> Option.value ~default:"active";
        summary = (match Json_util.assoc_member_opt "summary" json with Some (`String s) -> s | _ -> "");
        confidence =
          (match Json_util.assoc_member_opt "confidence" json with
          | Some (`Float value) -> value
          | Some (`Int value) -> float_of_int value
          | _ -> 0.0);
        generated_at = (match Json_util.assoc_member_opt "generated_at" json with Some (`String s) -> s | _ -> "");
        generated_at_unix =
          (match Json_util.assoc_member_opt "generated_at_unix" json with
          | Some (`Float value) -> value
          | Some (`Int value) -> float_of_int value
          | _ -> Masc_domain.parse_iso8601 ((match Json_util.assoc_member_opt "generated_at" json with Some (`String s) -> s | _ -> "")));
        fresh_until = (match Json_util.assoc_member_opt "fresh_until" json with Some (`String s) -> s | _ -> "");
        fresh_until_unix =
          (match json |> Json_util.assoc_member_opt "fresh_until_unix" with
          | Some (`Float value) -> value
          | Some (`Int value) -> float_of_int value
          | _ -> Masc_domain.parse_iso8601 ((match Json_util.assoc_member_opt "fresh_until" json with Some (`String s) -> s | _ -> "")));
        keeper_name =
          Json_util.get_string json "keeper_name"
          |> Option.value ~default:"operator-judge";
        model_name = Json_util.get_string json "model_name";
        runtime_name = Json_util.get_string json "runtime_name";
        evidence_refs =
          (match json |> Json_util.assoc_member_opt "evidence_refs" with
          | Some (`List items) -> List.filter_map (function `String s -> Some s | _ -> None) items
          | _ -> []);
        recommended_action =
          (match json |> Json_util.assoc_member_opt "recommended_action" with
          | Some (`Assoc _ as value) -> Some value
          | _ -> None);
        supersedes =
          (match json |> Json_util.assoc_member_opt "supersedes" with
          | Some (`List items) -> List.filter_map (function `String s -> Some s | _ -> None) items
          | _ -> []);
        fallback_used =
          Json_util.get_bool json "fallback_used"
          |> Option.value ~default:false;
        disagreement_with_truth =
          Json_util.get_bool json "disagreement_with_truth"
          |> Option.value ~default:false;
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
    ~f:(fun acc ~line_no:_ json ->
      try
        match of_yojson json with
        | Ok value -> value :: acc
        | Error _ -> acc
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
    ?generated_at_unix ~fresh_until ?fresh_until_unix ~keeper_name () =
  let supersedes =
    match latest_active config ~surface ~target_type ~target_id with
    | Some value -> [ value.judgment_id ]
    | None -> []
  in
  let generated_at_unix =
    match generated_at_unix with
    | Some value -> value
    | None -> Unix.gettimeofday ()
  in
  let fresh_until_unix =
    match fresh_until_unix with
    | Some value -> value
    | None -> Masc_domain.parse_iso8601 fresh_until
  in
  let value =
    {
      judgment_id = generate_id ();
      surface;
      target_type;
      target_id;
      status = "active";
      summary = String.trim summary;
      confidence = max 0.0 (min 1.0 confidence);
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
