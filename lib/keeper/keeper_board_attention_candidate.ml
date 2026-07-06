(* See .mli. *)

type signal_kind =
  | Post_created
  | Comment_added
  | Reaction_changed

type attention_authority =
  | Llm_judge_required

type wake_authority =
  | No_direct_wake

type candidate = {
  candidate_id : string;
  dedupe_key : string;
  keeper_name : string;
  post_id : string;
  signal_kind : signal_kind;
  author : string;
  title : string;
  content_preview : string;
  hearth : string option;
  updated_at : float option;
  recorded_at : float;
  attention_authority : attention_authority;
  wake_authority : wake_authority;
}

type record_result =
  [ `Recorded
  | `Duplicate of candidate
  | `Error of string
  ]

let candidate_dir base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "board_attention_candidates"

let candidate_path ~base_path ~keeper_name =
  Filename.concat
    (candidate_dir base_path)
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")

let ensure_candidate_dir ~base_path =
  let (_ : string) = Keeper_fs.ensure_dir (candidate_dir base_path) in
  ()

let signal_kind_to_string = function
  | Post_created -> "post_created"
  | Comment_added -> "comment_added"
  | Reaction_changed -> "reaction_changed"

let signal_kind_of_string = function
  | "post_created" -> Some Post_created
  | "comment_added" -> Some Comment_added
  | "reaction_changed" -> Some Reaction_changed
  | _ -> None

let attention_authority_to_string = function
  | Llm_judge_required -> "llm_judge_required"

let attention_authority_of_string = function
  | "llm_judge_required" -> Some Llm_judge_required
  | _ -> None

let wake_authority_to_string = function
  | No_direct_wake -> "no_direct_wake"

let wake_authority_of_string = function
  | "no_direct_wake" -> Some No_direct_wake
  | _ -> None

let candidate_id_of_dedupe_key key =
  Digestif.SHA256.(digest_string key |> to_hex)

let signal_kind_of_board_signal_kind = function
  | Board_dispatch.Board_post_created -> Post_created
  | Board_dispatch.Board_comment_added -> Comment_added
  | Board_dispatch.Board_reaction_changed _ -> Reaction_changed

let content_preview_max_bytes = 240

let short_preview ~max_len text =
  let text = String.trim text in
  if String.length text <= max_len then text else String.sub text 0 max_len

let updated_at_dedupe_segment = function
  | Some ts -> Printf.sprintf "%.6f" ts
  | None -> "none"

let bool_segment value = if value then "true" else "false"

let signal_payload_fingerprint (signal : Board_dispatch.board_signal) =
  let kind = signal_kind_of_board_signal_kind signal.kind in
  let reaction_segments =
    match signal.kind with
    | Board_dispatch.Board_post_created | Board_dispatch.Board_comment_added -> []
    | Board_dispatch.Board_reaction_changed reaction ->
      [ Board.reaction_target_type_to_string reaction.target_type
      ; reaction.target_id
      ; reaction.user_id
      ; reaction.emoji
      ; bool_segment reaction.reacted
      ]
  in
  let hearth_segment =
    match signal.hearth with
    | Some value -> value
    | None -> ""
  in
  let payload =
    String.concat "\031"
      ([ signal_kind_to_string kind
       ; signal.post_id
       ; signal.author
       ; signal.title
       ; signal.content
       ; hearth_segment
       ; updated_at_dedupe_segment signal.updated_at
       ]
       @ reaction_segments)
  in
  candidate_id_of_dedupe_key payload

let dedupe_key ~keeper_name ~(signal : Board_dispatch.board_signal) =
  let kind = signal_kind_of_board_signal_kind signal.kind in
  String.concat ":"
    [
      "board_attention_candidate";
      keeper_name;
      signal.post_id;
      signal_kind_to_string kind;
      signal_payload_fingerprint signal;
    ]

let of_board_signal ~keeper_name ~recorded_at signal =
  let signal_kind = signal_kind_of_board_signal_kind signal.kind in
  let dedupe_key = dedupe_key ~keeper_name ~signal in
  {
    candidate_id = candidate_id_of_dedupe_key dedupe_key;
    dedupe_key;
    keeper_name;
    post_id = signal.post_id;
    signal_kind;
    author = signal.author;
    title = signal.title;
    content_preview = short_preview ~max_len:content_preview_max_bytes signal.content;
    hearth = signal.hearth;
    updated_at = signal.updated_at;
    recorded_at;
    attention_authority = Llm_judge_required;
    wake_authority = No_direct_wake;
  }

let opt_string_field key = function
  | None -> []
  | Some value -> [ (key, `String value) ]

let opt_float_field key = function
  | None -> []
  | Some value -> [ (key, `Float value) ]

let candidate_to_json c =
  `Assoc
    ([ ("candidate_id", `String c.candidate_id);
       ("dedupe_key", `String c.dedupe_key);
       ("keeper_name", `String c.keeper_name);
       ("post_id", `String c.post_id);
       ("signal_kind", `String (signal_kind_to_string c.signal_kind));
       ("author", `String c.author);
       ("title", `String c.title);
       ("content_preview", `String c.content_preview);
       ("recorded_at", `Float c.recorded_at);
       ( "attention_authority",
         `String (attention_authority_to_string c.attention_authority) );
       ("wake_authority", `String (wake_authority_to_string c.wake_authority));
     ]
     @ opt_string_field "hearth" c.hearth
     @ opt_float_field "updated_at" c.updated_at)

let ( let* ) = Result.bind

let required_string key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) -> Ok value
      | _ -> Error (Printf.sprintf "missing string field %s" key))
  | _ -> Error "expected object"

let required_float key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Float value) -> Ok value
      | Some (`Int value) -> Ok (float_of_int value)
      | _ -> Error (Printf.sprintf "missing float field %s" key))
  | _ -> Error "expected object"

let optional_string key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | Some (`String _) | Some `Null | None -> None
      | Some _ -> None)
  | _ -> None

let optional_float key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Float value) -> Some value
      | Some (`Int value) -> Some (float_of_int value)
      | Some `Null | None -> None
      | Some _ -> None)
  | _ -> None

let candidate_of_json json =
  let* candidate_id = required_string "candidate_id" json in
  let* dedupe_key = required_string "dedupe_key" json in
  let* keeper_name = required_string "keeper_name" json in
  let* post_id = required_string "post_id" json in
  let* signal_kind_label = required_string "signal_kind" json in
  let* signal_kind =
    match signal_kind_of_string signal_kind_label with
    | Some kind -> Ok kind
    | None -> Error (Printf.sprintf "unknown signal_kind %S" signal_kind_label)
  in
  let* author = required_string "author" json in
  let* title = required_string "title" json in
  let* content_preview = required_string "content_preview" json in
  let* recorded_at = required_float "recorded_at" json in
  let* attention_authority_label = required_string "attention_authority" json in
  let* attention_authority =
    match attention_authority_of_string attention_authority_label with
    | Some authority -> Ok authority
    | None ->
      Error
        (Printf.sprintf
           "unknown attention_authority %S"
           attention_authority_label)
  in
  let* wake_authority_label = required_string "wake_authority" json in
  let* wake_authority =
    match wake_authority_of_string wake_authority_label with
    | Some authority -> Ok authority
    | None -> Error (Printf.sprintf "unknown wake_authority %S" wake_authority_label)
  in
  Ok
    {
      candidate_id;
      dedupe_key;
      keeper_name;
      post_id;
      signal_kind;
      author;
      title;
      content_preview;
      hearth = optional_string "hearth" json;
      updated_at = optional_float "updated_at" json;
      recorded_at;
      attention_authority;
      wake_authority;
    }

let parse_line ~file_path line =
  try
    match Yojson.Safe.from_string line |> candidate_of_json with
    | Ok candidate -> Some candidate
    | Error detail ->
      Log.Keeper.warn
        "keeper_board_attention_candidate: parse failed path=%s detail=%s"
        file_path
        detail;
      None
  with
  | Yojson.Json_error detail ->
    Log.Keeper.warn
      "keeper_board_attention_candidate: invalid json path=%s detail=%s"
      file_path
      detail;
    None

let load_candidates ~base_path ~keeper_name =
  let path = candidate_path ~base_path ~keeper_name in
  if not (Sys.file_exists path) then []
  else
    try
      let candidates_rev, _boundary =
        Fs_compat.fold_appended_lines ~path ~from:0 ~init:[]
          ~f:(fun acc line ->
            let line = String.trim line in
            if String.equal line "" then acc
            else
              match parse_line ~file_path:path line with
              | Some candidate -> candidate :: acc
              | None -> acc)
      in
      List.rev candidates_rev
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn
        "keeper_board_attention_candidate: load failed keeper=%s detail=%s"
        (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name)
        (Printexc.to_string exn);
      []

let recent_dedup_window_bytes = Keeper_external_attention.dedup_window_bytes

let load_recent_candidates ~base_path ~keeper_name =
  let path = candidate_path ~base_path ~keeper_name in
  match Fs_compat.file_size path with
  | None -> []
  | Some size when size <= recent_dedup_window_bytes ->
    load_candidates ~base_path ~keeper_name
  | Some size ->
    let from = size - recent_dedup_window_bytes in
    let slice =
      Fs_compat.read_slice ~path ~from ~len:recent_dedup_window_bytes
    in
    (match String.index_opt slice '\n', String.rindex_opt slice '\n' with
     | Some i, Some j when j > i ->
       String.sub slice (i + 1) (j - i - 1)
       |> String.split_on_char '\n'
       |> List.filter_map (fun line ->
              let line = String.trim line in
              if String.equal line "" then None else parse_line ~file_path:path line)
     | _ -> [])

let candidate_by_id candidates candidate_id =
  List.find_opt
    (fun candidate -> String.equal candidate.candidate_id candidate_id)
    candidates

let append_candidate ~base_path candidate =
  try
    ensure_candidate_dir ~base_path;
    let path = candidate_path ~base_path ~keeper_name:candidate.keeper_name in
    Fs_compat.append_file path (Yojson.Safe.to_string (candidate_to_json candidate) ^ "\n");
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let detail = Printexc.to_string exn in
    Log.Keeper.warn
      "keeper_board_attention_candidate: append failed keeper=%s detail=%s"
      (Workspace_utils_backend_setup.sanitize_namespace_segment candidate.keeper_name)
      detail;
    Error detail

let record ~base_path candidate =
  let recent =
    load_recent_candidates ~base_path ~keeper_name:candidate.keeper_name
  in
  match candidate_by_id recent candidate.candidate_id with
  | Some existing -> `Duplicate existing
  | None -> (
      match append_candidate ~base_path candidate with
      | Ok () -> `Recorded
      | Error detail -> `Error detail)
