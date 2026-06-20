(** Durable draft-skill candidate store. *)

type stored_draft =
  { candidate : Skill_candidate_projection.skill_candidate
  ; dir : string
  ; json_path : string
  ; toml_path : string
  ; skill_md_path : string
  ; index_path : string
  }

let drafts_dir ~base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "draft-skills"
;;

let safe_component raw =
  let raw = raw |> String.trim |> String.lowercase_ascii in
  let buf = Buffer.create (String.length raw) in
  String.iter
    (function
      | 'a' .. 'z' | '0' .. '9' | '-' | '_' as c -> Buffer.add_char buf c
      | _ -> Buffer.add_char buf '-')
    raw;
  let s = Buffer.contents buf in
  let len = String.length s in
  let rec left i =
    if i >= len then len else if Char.equal s.[i] '-' then left (i + 1) else i
  in
  let rec right i =
    if i < 0 then -1 else if Char.equal s.[i] '-' then right (i - 1) else i
  in
  let l = left 0 in
  let r = right (len - 1) in
  if l > r then "untitled" else String.sub s l (r - l + 1)
;;

let draft_dir ~base_path (candidate : Skill_candidate_projection.skill_candidate) =
  Filename.concat (drafts_dir ~base_path) (safe_component candidate.id)
;;

let string_escape_toml s =
  let buf = Buffer.create (String.length s + 8) in
  String.iter
    (function
      | '\\' -> Buffer.add_string buf "\\\\"
      | '"' -> Buffer.add_string buf "\\\""
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

let toml_string s = Printf.sprintf "\"%s\"" (string_escape_toml s)

let toml_string_list name values =
  Printf.sprintf "%s = [%s]\n" name
    (values |> List.map toml_string |> String.concat ", ")
;;

let render_candidate_toml (c : Skill_candidate_projection.skill_candidate) =
  String.concat ""
    [ "schema = \"masc.skill_candidate.draft.v1\"\n"
    ; "promotion_state = "
    ; toml_string (Skill_candidate_projection.promotion_state_to_string c.promotion_state)
    ; "\n"
    ; "installable = false\n"
    ; "requires_human_approval = true\n"
    ; "id = "
    ; toml_string c.id
    ; "\n"
    ; "agent_name = "
    ; toml_string c.agent_name
    ; "\n"
    ; "source_kind = "
    ; toml_string c.source_kind
    ; "\n"
    ; "source_id = "
    ; toml_string c.source_id
    ; "\n"
    ; "source_ref = "
    ; toml_string c.source_ref
    ; "\n"
    ; "pattern = "
    ; toml_string c.pattern
    ; "\n"
    ; Printf.sprintf "success_count = %d\n" c.success_count
    ; Printf.sprintf "failure_count = %d\n" c.failure_count
    ; Printf.sprintf "confidence = %.6f\n" c.confidence
    ; toml_string_list "evidence_refs" c.evidence_refs
    ; toml_string_list "applicable_tools" c.applicable_tools
    ; toml_string_list "risk_notes" c.risk_notes
    ]
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

let write_candidate ~base_path (candidate : Skill_candidate_projection.skill_candidate) =
  let dir = draft_dir ~base_path candidate in
  let json_path = Filename.concat dir "candidate.json" in
  let toml_path = Filename.concat dir "candidate.toml" in
  let skill_md_path = Filename.concat dir "SKILL.md" in
  let index_path = Filename.concat (drafts_dir ~base_path) "index.jsonl" in
  let* () =
    write_file json_path
      (Yojson.Safe.pretty_to_string (Skill_candidate_projection.to_json candidate)
       ^ "\n")
  in
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
