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

let candidate_identity_key (candidate : Skill_candidate_projection.skill_candidate) =
  String.concat "\n"
    [ candidate.source_kind; candidate.agent_name; candidate.source_ref ]
;;

let summary_identity_key (summary : draft_summary) =
  String.concat "\n" [ summary.source_kind; summary.agent_name; summary.source_ref ]
;;

let candidate_component (candidate : Skill_candidate_projection.skill_candidate) =
  Review_artifact_store.component
    ~display_id:candidate.id
    ~identity_key:(candidate_identity_key candidate)
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

let ( let* ) = Result.bind

let json_string_opt name json =
  match Yojson.Safe.Util.member name json with
  | `String s -> Some s
  | _ -> None
;;

let candidate_index_key
      (c : Skill_candidate_projection.skill_candidate)
      ~dir
      ~json_path
      ~toml_path
      ~skill_md_path
  =
  ( c.id
  , c.agent_name
  , c.source_kind
  , c.source_ref
  , Skill_candidate_projection.promotion_state_to_string c.promotion_state
  , dir
  , json_path
  , toml_path
  , skill_md_path )
;;

let index_key_of_json json =
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
      ( id
      , agent_name
      , source_kind
      , source_ref
      , promotion_state
      , dir
      , json_path
      , toml_path
      , skill_md_path )
  | _ -> None
;;

let load_index_keys ~index_path =
  try
    let keys = Hashtbl.create 1024 in
    let keys =
      Fs_compat.fold_jsonl_lines index_path ~init:keys
        ~f:(fun keys ~line_no:_ json ->
          match index_key_of_json json with
          | Some key ->
            Hashtbl.replace keys key ();
            keys
          | None -> keys)
    in
    Ok keys
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "%s: %s" index_path (Printexc.to_string exn))
;;

let candidate_json_content candidate =
  Yojson.Safe.pretty_to_string (Skill_candidate_projection.to_json candidate) ^ "\n"
;;

let stored_candidate ~base_path candidate =
  { candidate
  ; dir = draft_dir ~base_path candidate
  ; json_path = candidate_json_path ~base_path candidate
  ; toml_path = candidate_toml_path ~base_path candidate
  ; skill_md_path = candidate_skill_md_path ~base_path candidate
  ; index_path = index_path ~base_path
  }
;;

let stored_candidate_artifacts (stored : stored_draft) =
  [ stored.json_path, candidate_json_content stored.candidate
  ; stored.toml_path, render_candidate_toml stored.candidate
  ; stored.skill_md_path, Skill_candidate_projection.render_skill_draft stored.candidate
  ]
;;

let stored_candidate_index_event (stored : stored_draft) =
  index_event_json stored.candidate
    ~dir:stored.dir
    ~json_path:stored.json_path
    ~toml_path:stored.toml_path
    ~skill_md_path:stored.skill_md_path
;;

let stored_candidate_index_key (stored : stored_draft) =
  candidate_index_key stored.candidate
    ~dir:stored.dir
    ~json_path:stored.json_path
    ~toml_path:stored.toml_path
    ~skill_md_path:stored.skill_md_path
;;

let write_candidate ~base_path (candidate : Skill_candidate_projection.skill_candidate) =
  let stored = stored_candidate ~base_path candidate in
  let* () =
    Review_artifact_store.write_artifacts
      ~index_path:stored.index_path
      ~artifacts:(stored_candidate_artifacts stored)
      ~index_event:(stored_candidate_index_event stored)
  in
  Ok stored
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

let write_candidate_if_changed_with_index ~index_keys ~base_path candidate =
  (* Artifact files and the index are intentionally checked together: a prior
     write can leave complete artifacts but miss the final index append. The
     next post-turn pass should repair that listing row instead of treating the
     draft as fully persisted. This is a safety net until #21871 makes the
     index/artifact persistence atomic or derives one side from the other. *)
  let stored = stored_candidate ~base_path candidate in
  let key = stored_candidate_index_key stored in
  let indexed = Hashtbl.mem index_keys key in
  let artifacts = stored_candidate_artifacts stored in
  let* changed =
    if Review_artifact_store.artifacts_unchanged artifacts && indexed
    then Ok false
    else
      let* () =
        Review_artifact_store.write_artifacts
          ~index_path:stored.index_path
          ~artifacts
          ~index_event:(stored_candidate_index_event stored)
      in
      Hashtbl.replace index_keys key ();
      Ok true
  in
  if changed then Ok (Some stored) else Ok None
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

let fact_candidates facts ~keeper_id =
  Skill_candidate_projection.candidates_of_memory_facts ~agent_name:keeper_id facts
;;

let fact_candidates_for_post_turn ~base_path ~keeper_id ~fact_tail_limit =
  let facts =
    if fact_tail_limit <= 0
    then []
    else
      Keeper_memory_os_io.read_facts_tail_for_base_path ~base_path ~keeper_id
        ~n:fact_tail_limit
  in
  fact_candidates facts ~keeper_id
;;

let strict_fact_candidates_for_post_turn ~base_path ~keeper_id ~fact_tail_limit =
  if fact_tail_limit <= 0
  then Ok []
  else
    let keepers_dir =
      Common.keepers_runtime_dir_of_base ~base_path
    in
    let* facts =
      Keeper_memory_os_io.read_facts_all_strict_for_keepers_dir
        ~keepers_dir
        ~keeper_id
    in
    Ok
      (facts
       |> List_util.take_last fact_tail_limit
       |> fact_candidates ~keeper_id)
;;

let write_projected_candidates ~base_path candidates =
  let candidates = dedup_candidates candidates in
  let* index_keys = load_index_keys ~index_path:(index_path ~base_path) in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | candidate :: rest ->
      let* stored = write_candidate_if_changed_with_index ~index_keys ~base_path candidate in
      let acc =
        match stored with
        | Some stored -> stored :: acc
        | None -> acc
      in
      loop acc rest
  in
  loop [] candidates
;;

let write_post_turn_candidates ~base_path ~keeper_id ~fact_tail_limit ~procedure_limit =
  let fact_candidates =
    fact_candidates_for_post_turn ~base_path ~keeper_id ~fact_tail_limit
  in
  let procedure_candidates =
    if procedure_limit <= 0
    then []
    else
      Skill_candidate_projection.top_candidates ~base_path ~agent_name:keeper_id
        ~limit:procedure_limit
  in
  write_projected_candidates
    ~base_path
    (fact_candidates @ procedure_candidates)
;;

let procedural_load_error_to_string
      (error : Procedural_memory.load_error)
  =
  Printf.sprintf
    "%s:%d: %s"
    error.path
    error.line_number
    error.message
;;

let write_all_post_turn_candidates ~base_path ~keeper_id ~fact_tail_limit =
  let* fact_candidates =
    strict_fact_candidates_for_post_turn
      ~base_path
      ~keeper_id
      ~fact_tail_limit
  in
  let* procedures =
    Procedural_memory.load_procedures_strict
      ~base_path
      ~agent_name:keeper_id
      ()
    |> Result.map_error (fun errors ->
      String.concat
        "; "
        (List.map procedural_load_error_to_string errors))
  in
  let procedure_candidates =
    procedures
    |> List.filter Procedural_memory.is_crystallized
    |> Skill_candidate_projection.candidates_of_procedures
  in
  write_projected_candidates
    ~base_path
    (fact_candidates @ procedure_candidates)
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

let list_drafts ~base_path ~limit =
  let index_path = index_path ~base_path in
  let limit = max 0 limit in
  let* (total, items) =
    Review_artifact_store.list_index
      ~index_path
      ~limit
      ~of_json:draft_summary_of_index_event
      ~identity_key:summary_identity_key
  in
  Ok { total; shown = List.length items; limit; index_path; items }
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
