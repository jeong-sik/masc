(** Durable draft-skill candidate store. *)

type stored_draft =
  { candidate : Skill_candidate_projection.skill_candidate
  ; dir : string
  ; json_path : string
  ; toml_path : string
  ; skill_md_path : string
  ; index_path : string
  }

type draft_summary =
  { id : string
  ; agent_name : string
  ; source_kind : string
  ; source_ref : string
  ; promotion_state : string
  ; dir : string
  ; json_path : string
  ; toml_path : string
  ; skill_md_path : string
  ; created_at : float option
  }

type draft_listing =
  { total : int
  ; shown : int
  ; limit : int
  ; index_path : string
  ; items : draft_summary list
  }

let drafts_dir ~base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "draft-skills"
;;

let index_path ~base_path = Filename.concat (drafts_dir ~base_path) "index.jsonl"

let component_hash raw =
  Digestif.SHA256.(digest_string raw |> to_hex) |> fun hex -> String.sub hex 0 16
;;

let component_prefix raw =
  let safe =
    Workspace_utils_backend_setup.sanitize_namespace_segment raw
    |> String.lowercase_ascii
  in
  let safe =
    match safe with
    | "default" when String.equal (String.trim raw) "" -> "untitled"
    | other -> other
  in
  if String.length safe > 48 then String.sub safe 0 48 else safe
;;

let candidate_identity_key (candidate : Skill_candidate_projection.skill_candidate) =
  String.concat "\n"
    [ candidate.source_kind; candidate.agent_name; candidate.source_ref ]
;;

let summary_identity_key (summary : draft_summary) =
  String.concat "\n" [ summary.source_kind; summary.agent_name; summary.source_ref ]
;;

let candidate_component (candidate : Skill_candidate_projection.skill_candidate) =
  component_prefix candidate.id ^ "-" ^ component_hash (candidate_identity_key candidate)
;;

let draft_dir ~base_path (candidate : Skill_candidate_projection.skill_candidate) =
  Filename.concat (drafts_dir ~base_path) (candidate_component candidate)
;;

let candidate_json_path ~base_path candidate =
  Filename.concat (draft_dir ~base_path candidate) "candidate.json"
;;

let candidate_toml_path ~base_path candidate =
  Filename.concat (draft_dir ~base_path candidate) "candidate.toml"
;;

let candidate_skill_md_path ~base_path candidate =
  Filename.concat (draft_dir ~base_path candidate) "SKILL.md"
;;

let toml_string_array values =
  Otoml.TomlArray (List.map (fun s -> Otoml.TomlString s) values)
;;

let render_candidate_toml (c : Skill_candidate_projection.skill_candidate) =
  Otoml.TomlTable
    [ "schema", Otoml.string "masc.skill_candidate.draft.v1"
    ; ( "promotion_state"
      , Otoml.string
          (Skill_candidate_projection.promotion_state_to_string c.promotion_state) )
    ; "installable", Otoml.boolean false
    ; "requires_human_approval", Otoml.boolean true
    ; "id", Otoml.string c.id
    ; "agent_name", Otoml.string c.agent_name
    ; "source_kind", Otoml.string c.source_kind
    ; "source_id", Otoml.string c.source_id
    ; "source_ref", Otoml.string c.source_ref
    ; "pattern", Otoml.string c.pattern
    ; "success_count", Otoml.integer c.success_count
    ; "failure_count", Otoml.integer c.failure_count
    ; "confidence", Otoml.TomlFloat c.confidence
    ; "evidence_refs", toml_string_array c.evidence_refs
    ; "applicable_tools", toml_string_array c.applicable_tools
    ; "risk_notes", toml_string_array c.risk_notes
    ]
  |> Otoml.Printer.to_string
;;

let write_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  match Fs_compat.save_file_atomic path content with
  | Ok () -> Ok ()
  | Error msg -> Error (Printf.sprintf "%s: %s" path msg)
;;

let index_event_json (c : Skill_candidate_projection.skill_candidate) ~dir ~json_path
      ~toml_path ~skill_md_path =
  `Assoc
    [ "schema", `String "masc.skill_candidate.index.v1"
    ; "id", `String c.id
    ; "agent_name", `String c.agent_name
    ; "source_kind", `String c.source_kind
    ; "source_ref", `String c.source_ref
    ; "promotion_state"
      , `String (Skill_candidate_projection.promotion_state_to_string c.promotion_state)
    ; "dir", `String dir
    ; "json_path", `String json_path
    ; "toml_path", `String toml_path
    ; "skill_md_path", `String skill_md_path
    ; "ts", `Float (Time_compat.now ())
    ]
;;

let append_index index_path event =
  try
    Keeper_types_support.append_jsonl_line index_path event;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "%s: %s" index_path (Printexc.to_string exn))
;;

let ( let* ) = Result.bind

let candidate_json_content candidate =
  Yojson.Safe.pretty_to_string (Skill_candidate_projection.to_json candidate) ^ "\n"
;;

let json_string_opt name json =
  match Yojson.Safe.Util.member name json with
  | `String s -> Some s
  | _ -> None
;;

let candidate_artifacts ~base_path candidate =
  [ candidate_json_path ~base_path candidate, candidate_json_content candidate
  ; candidate_toml_path ~base_path candidate, render_candidate_toml candidate
  ; ( candidate_skill_md_path ~base_path candidate
    , Skill_candidate_projection.render_skill_draft candidate )
  ]
;;

let write_candidate ~base_path (candidate : Skill_candidate_projection.skill_candidate) =
  let dir = draft_dir ~base_path candidate in
  let json_path = candidate_json_path ~base_path candidate in
  let toml_path = candidate_toml_path ~base_path candidate in
  let skill_md_path = candidate_skill_md_path ~base_path candidate in
  let index_path = index_path ~base_path in
  let* () = write_file json_path (candidate_json_content candidate) in
  let* () = write_file toml_path (render_candidate_toml candidate) in
  let* () = write_file skill_md_path (Skill_candidate_projection.render_skill_draft candidate) in
  let* () =
    append_index index_path
      (index_event_json candidate ~dir ~json_path ~toml_path ~skill_md_path)
  in
  Ok { candidate; dir; json_path; toml_path; skill_md_path; index_path }
;;

let write_candidates ~base_path candidates =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | candidate :: rest ->
      let* stored = write_candidate ~base_path candidate in
      loop (stored :: acc) rest
  in
  loop [] candidates
;;

let read_file_opt = Fs_compat.load_file_opt

let index_event_matches_candidate ~base_path
    (candidate : Skill_candidate_projection.skill_candidate) json =
  let dir = draft_dir ~base_path candidate in
  let json_path = candidate_json_path ~base_path candidate in
  let toml_path = candidate_toml_path ~base_path candidate in
  let skill_md_path = candidate_skill_md_path ~base_path candidate in
  match
    ( json_string_opt "id" json
    , json_string_opt "agent_name" json
    , json_string_opt "source_kind" json
    , json_string_opt "source_ref" json
    , json_string_opt "promotion_state" json
    , json_string_opt "dir" json
    , json_string_opt "json_path" json
    , json_string_opt "toml_path" json
    , json_string_opt "skill_md_path" json )
  with
  | ( Some id
    , Some agent_name
    , Some source_kind
    , Some source_ref
    , Some promotion_state
    , Some indexed_dir
    , Some indexed_json_path
    , Some indexed_toml_path
    , Some indexed_skill_md_path ) ->
    String.equal id candidate.id
    && String.equal agent_name candidate.agent_name
    && String.equal source_kind candidate.source_kind
    && String.equal source_ref candidate.source_ref
    && String.equal promotion_state
         (Skill_candidate_projection.promotion_state_to_string
            candidate.promotion_state)
    && String.equal indexed_dir dir
    && String.equal indexed_json_path json_path
    && String.equal indexed_toml_path toml_path
    && String.equal indexed_skill_md_path skill_md_path
  | _ -> false
;;

let index_contains_candidate ~base_path candidate =
  let index_path = index_path ~base_path in
  if not (Fs_compat.file_exists index_path)
  then Ok false
  else
    try
      Ok
        (Fs_compat.load_jsonl index_path
         |> List.exists (index_event_matches_candidate ~base_path candidate))
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printf.sprintf "%s: %s" index_path (Printexc.to_string exn))
;;

let write_candidate_if_changed ~base_path candidate =
  (* Artifact files and the index are intentionally checked together: a prior
     write can leave complete artifacts but miss the final index append. The
     next post-turn pass should repair that listing row instead of treating the
     draft as fully persisted. This is a safety net until #21871 makes the
     index/artifact persistence atomic or derives one side from the other. *)
  let artifacts_unchanged =
    candidate_artifacts ~base_path candidate
    |> List.for_all (fun (path, expected) ->
      match read_file_opt path with
      | Some content -> String.equal content expected
      | None -> false)
  in
  let* indexed = index_contains_candidate ~base_path candidate in
  if artifacts_unchanged && indexed
  then Ok None
  else (
    let* stored = write_candidate ~base_path candidate in
    Ok (Some stored))
;;

let dedup_candidates candidates =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun (candidate : Skill_candidate_projection.skill_candidate) ->
       let key = candidate_identity_key candidate in
       if Hashtbl.mem seen key
       then false
       else (
         Hashtbl.add seen key ();
         true))
    candidates
;;

let write_post_turn_candidates ~base_path ~keeper_id ~fact_tail_limit ~procedure_limit =
  let facts =
    if fact_tail_limit <= 0
    then []
    else
      Keeper_memory_os_io.read_facts_tail_for_base_path ~base_path ~keeper_id
        ~n:fact_tail_limit
  in
  let fact_candidates =
    Skill_candidate_projection.candidates_of_memory_facts ~agent_name:keeper_id facts
  in
  let procedure_candidates =
    if procedure_limit <= 0
    then []
    else
      Skill_candidate_projection.top_candidates ~base_path ~agent_name:keeper_id
        ~limit:procedure_limit
  in
  let candidates = dedup_candidates (fact_candidates @ procedure_candidates) in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | candidate :: rest ->
      let* stored = write_candidate_if_changed ~base_path candidate in
      let acc =
        match stored with
        | Some stored -> stored :: acc
        | None -> acc
      in
      loop acc rest
  in
  loop [] candidates
;;

let json_float_opt name json =
  match Yojson.Safe.Util.member name json with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None
;;

let draft_summary_of_index_event json =
  match
    ( json_string_opt "id" json
    , json_string_opt "agent_name" json
    , json_string_opt "source_kind" json
    , json_string_opt "source_ref" json
    , json_string_opt "promotion_state" json
    , json_string_opt "dir" json
    , json_string_opt "json_path" json
    , json_string_opt "toml_path" json
    , json_string_opt "skill_md_path" json )
  with
  | ( Some id
    , Some agent_name
    , Some source_kind
    , Some source_ref
    , Some promotion_state
    , Some dir
    , Some json_path
    , Some toml_path
    , Some skill_md_path ) ->
    Some
      { id
      ; agent_name
      ; source_kind
      ; source_ref
      ; promotion_state
      ; dir
      ; json_path
      ; toml_path
      ; skill_md_path
      ; created_at = json_float_opt "ts" json
      }
  | _ -> None
;;

let take n xs =
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n xs
;;

let latest_unique summaries =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun (summary : draft_summary) ->
      let key = summary_identity_key summary in
      if Hashtbl.mem seen key
      then false
      else (
        Hashtbl.add seen key ();
        true))
    summaries
;;

let list_drafts ~base_path ~limit =
  let index_path = index_path ~base_path in
  let limit = max 0 limit in
  try
    let items =
      if Fs_compat.file_exists index_path
      then
        Fs_compat.load_jsonl index_path
        |> List.rev
        |> List.filter_map draft_summary_of_index_event
        |> latest_unique
      else []
    in
    let total = List.length items in
    let items = take limit items in
    Ok { total; shown = List.length items; limit; index_path; items }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "%s: %s" index_path (Printexc.to_string exn))
;;

let json_option_float = function
  | Some f -> `Float f
  | None -> `Null
;;

let draft_summary_to_json (summary : draft_summary) =
  `Assoc
    [ "id", `String summary.id
    ; "agent_name", `String summary.agent_name
    ; "source_kind", `String summary.source_kind
    ; "source_ref", `String summary.source_ref
    ; "promotion_state", `String summary.promotion_state
    ; "dir", `String summary.dir
    ; "json_path", `String summary.json_path
    ; "toml_path", `String summary.toml_path
    ; "skill_md_path", `String summary.skill_md_path
    ; "created_at", json_option_float summary.created_at
    ]
;;
