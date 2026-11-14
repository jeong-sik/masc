let ledger_filename = "articles.jsonl"

let ledger_path ~base_path =
  Filename.concat
    (Config_dir_resolver.constitution_dir ~base_path)
    ledger_filename

type append_error =
  | Directory_unavailable of {
      path : string;
      detail : string;
    }
  | Ledger_moved of {
      expected : int;
      actual : int;
    }
  | Write_failed of {
      path : string;
      detail : string;
    }

let append_error_to_string = function
  | Directory_unavailable { path; detail } ->
    Printf.sprintf "constitution directory %s is unavailable: %s" path detail
  | Ledger_moved { expected; actual } ->
    Printf.sprintf
      "the constitution ledger moved from %d to %d bytes while this call was \
       deciding; read it again"
      expected actual
  | Write_failed { path; detail } ->
    Printf.sprintf "constitution ledger %s could not be appended: %s" path
      detail

(* The durable failure carries a nested rollback story this caller cannot act
   on differently; the phase is what distinguishes the outcomes. *)
let append_failure_detail : Fs_compat.private_jsonl_append_error -> string =
  function
  | Fs_compat.Incomplete_jsonl_tail ->
    "the offset counts an unfinished last line as part of the ledger"
  | Fs_compat.Incomplete_jsonl_tail_truncate_failed _ ->
    "the ledger's unfinished last line could not be cut"
  | Fs_compat.Existing_jsonl_refused _ -> "the existing entry was refused"
  | Fs_compat.Invalid_jsonl_suffix -> "the entry is not one complete JSONL line"
  | Fs_compat.Negative_expected_end_offset offset ->
    Printf.sprintf "the caller passed a negative end offset (%d)" offset
  | Fs_compat.End_offset_mismatch { expected; actual } ->
    Printf.sprintf "the ledger ends at %d, not %d" actual expected
  | Fs_compat.Durable_jsonl_append_failed _ ->
    "the durable append did not commit"

let append_at ~base_path ~expected_end_offset entry =
  let dir = Config_dir_resolver.constitution_dir ~base_path in
  let path = ledger_path ~base_path in
  let line =
    Yojson.Safe.to_string (World_constitution_wire.entry_to_json entry) ^ "\n"
  in
  (* The offset-checked append does not create its directory, so this is the
     only creator on the path. Memoized because it runs on every append. *)
  match Fs_compat.mkdir_p_memoized dir with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error (Directory_unavailable { path = dir; detail = Printexc.to_string exn })
  | () -> (
    match
      Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result path
        ~expected_end_offset line
    with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      Error (Write_failed { path; detail = Printexc.to_string exn })
    | Fs_compat.Private_file_succeeded _
    | Fs_compat.Private_file_succeeded_with_cleanup_failure _ ->
      (* The durable effect committed. A cleanup failure is about descriptor
         settlement, and reporting it as a write failure would invite a retry
         that appends the entry twice. *)
      Ok ()
    | Fs_compat.Private_file_failed
        (Fs_compat.End_offset_mismatch { expected; actual })
    | Fs_compat.Private_file_failed_with_cleanup_failure
        { error = Fs_compat.End_offset_mismatch { expected; actual }; _ } ->
      Error (Ledger_moved { expected; actual })
    | Fs_compat.Private_file_failed
        (( Fs_compat.Incomplete_jsonl_tail
         | Fs_compat.Incomplete_jsonl_tail_truncate_failed _
         | Fs_compat.Existing_jsonl_refused _
         | Fs_compat.Invalid_jsonl_suffix
         | Fs_compat.Negative_expected_end_offset _
         | Fs_compat.Durable_jsonl_append_failed _ ) as error)
    | Fs_compat.Private_file_failed_with_cleanup_failure
        { error =
            ( Fs_compat.Incomplete_jsonl_tail
            | Fs_compat.Incomplete_jsonl_tail_truncate_failed _
            | Fs_compat.Existing_jsonl_refused _
            | Fs_compat.Invalid_jsonl_suffix
            | Fs_compat.Negative_expected_end_offset _
            | Fs_compat.Durable_jsonl_append_failed _ ) as error
        ; _ } ->
      Error (Write_failed { path; detail = append_failure_detail error }))

type line_end =
  | Newline_terminated
  | Unterminated_final_line

let line_end_to_string = function
  | Newline_terminated -> "newline_terminated"
  | Unterminated_final_line -> "unterminated_final_line"

type rejected_line = {
  line_number : int;
  line_end : line_end;
  detail : string;
}

type isolated_line = {
  line_number : int;
  subject : string;
  article_ids : World_constitution_types.Article_id.t list;
}

type ledger = {
  end_offset : int;
  articles : World_constitution_types.t list;
  entries : World_constitution_types.entry list;
  rejected : rejected_line list;
  isolated : isolated_line list;
}

type read_error =
  | Unreadable of {
      path : string;
      detail : string;
    }

let read_error_to_string = function
  | Unreadable { path; detail } ->
    Printf.sprintf "constitution ledger %s could not be read: %s" path detail

let same_id id (article : World_constitution_types.t) =
  World_constitution_types.Article_id.equal article.id id

let without_ids held ids =
  List.filter
    (fun article -> not (List.exists (fun id -> same_id id article) ids))
    held

(* Folding keeps the order a world wrote its norms in. Re-adding an article
   that is still held replaces it in place, because that is an edit; re-adding
   one that was removed puts it at the end, because the world changed its mind
   and that is when it did. A replacement retires its bundle first and then
   follows the same add rule, so its article lands at the end under its own
   id (RFC-0504). *)
let rec apply held = function
  | World_constitution_types.Added article ->
    if List.exists (same_id article.id) held then
      List.map
        (fun existing -> if same_id article.id existing then article else existing)
        held
    else held @ [ article ]
  | World_constitution_types.Replaced { superseded; article; _ } ->
    let retired = without_ids held superseded in
    apply retired (World_constitution_types.Added article)
  | World_constitution_types.Removed { id; _ } ->
    without_ids held [ id ]

(* An unresolved move is not admitted as a norm or a retirement. Its targets
   are uncertain too: skipping a removal would resurrect an earlier norm,
   and skipping an edit would silently keep the text it disputed. Withhold
   those ids from the prompt while retaining the move and its targets in the
   isolation report. A later resolved write can adopt an id again. *)
let article_ids_of_entry = function
  | World_constitution_types.Added article -> [ article.id ]
  | World_constitution_types.Replaced { superseded; article; _ } ->
    article.id :: superseded
  | World_constitution_types.Removed { id; _ } -> [ id ]

(* Both the mover and the author of any new text must resolve. The tool
   writes them as the same keeper, but a decoded replacement need not. *)
let subjects_of_entry = function
  | World_constitution_types.Added article -> [ article.author ]
  | World_constitution_types.Replaced { by; article; _ } -> [ by; article.author ]
  | World_constitution_types.Removed { by; _ } -> [ by ]

(* Every append writes its move and the newline in one piece, so the moves
   end right after the last newline. Bytes after it are an append that stopped
   part way: not a move, and cut by the next [append_at]. *)
let complete_lines contents =
  match String.rindex_opt contents '\n' with
  | Some newline -> String.sub contents 0 (newline + 1)
  | None -> ""

let unfinished_line_detail =
  "the line has no newline, so its append did not finish; the next write cuts it"

let parse_with ~keep_history ~resolve_subject contents =
  let end_offset = String.length (complete_lines contents) in
  let rec scan line_number held entries rejected isolated = function
    | [] -> { end_offset; articles = held; entries = List.rev entries;
              rejected = List.rev rejected; isolated = List.rev isolated }
    | line :: rest ->
      if String.equal (String.trim line) "" then
        scan (line_number + 1) held entries rejected isolated rest
      else (
        let reject line_end detail =
          scan (line_number + 1) held entries
            ({ line_number; line_end; detail } :: rejected) isolated rest
        in
        (* [split_on_char] leaves the text after the last newline as the
           final element, so only that element can be unterminated. It is
           reported and never decoded: bytes that happen to read as a whole
           move would otherwise be held now and gone after the next append. *)
        match rest with
        | [] -> reject Unterminated_final_line unfinished_line_detail
        | _ :: _ -> (
          match Yojson.Safe.from_string line with
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception exn -> reject Newline_terminated (Printexc.to_string exn)
          | json -> (
            match World_constitution_wire.entry_of_json json with
            | Error error ->
              reject Newline_terminated
                (World_constitution_wire.decode_error_to_string error)
            | Ok entry ->
              let entries = if keep_history then entry :: entries else entries in
              match List.find_opt (fun subject -> not (resolve_subject subject))
                      (subjects_of_entry entry) with
              | None ->
                scan (line_number + 1) (apply held entry) entries rejected isolated rest
              | Some subject ->
                let article_ids = article_ids_of_entry entry in
                scan (line_number + 1) (without_ids held article_ids) entries rejected
                  ({ line_number; subject; article_ids } :: isolated) rest)))
  in
  scan 1 [] [] [] [] (String.split_on_char '\n' contents)

let parse ~resolve_subject contents =
  parse_with ~keep_history:true ~resolve_subject contents

type projection_status = Resolved | Isolated_history

let projection_status (ledger : ledger) =
  match ledger.isolated with
  | [] -> Resolved
  | _ :: _ -> Isolated_history

let read_contents ~base_path =
  let path = ledger_path ~base_path in
  match Fs_compat.load_file_opt path with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Unreadable { path; detail = Printexc.to_string exn })
  | None -> Ok None
  | Some contents -> Ok (Some contents)

let load ~base_path ~resolve_subject =
  match read_contents ~base_path with
  | Error _ as error -> error
  | Ok None -> Ok { end_offset = 0; articles = []; entries = []; rejected = []; isolated = [] }
  | Ok (Some contents) -> Ok (parse ~resolve_subject contents)

let load_articles ~base_path ~resolve_subject =
  match read_contents ~base_path with
  | Error _ as error -> error
  | Ok None -> Ok []
  | Ok (Some contents) -> Ok (parse_with ~keep_history:false ~resolve_subject contents).articles

type position = {
  end_offset : int;
  digest : string;
}

type held_projection = {
  articles : World_constitution_types.t list;
  at : position;
  status : projection_status;
}

let position_of contents =
  { end_offset = String.length contents;
    digest = Agent_core_sha256.(digest_string contents |> to_hex) }

let load_held ~base_path ~resolve_subject =
  match read_contents ~base_path with
  | Error _ as error -> error
  | Ok contents ->
    let contents = Option.value contents ~default:"" in
    let ledger = parse_with ~keep_history:false ~resolve_subject contents in
    Ok { articles = ledger.articles; at = position_of (complete_lines contents);
         status = projection_status ledger }

(* Appends never rewrite a complete line already written, and a position ends
   at one, so the first [end_offset] bytes of the ledger now are the ledger
   [position] read, exactly when they still hash to its digest. *)
let load_articles_at ~base_path ~resolve_subject (position : position) =
  match read_contents ~base_path with
  | Error _ as error -> error
  | Ok contents ->
    let contents = Option.value contents ~default:"" in
    if position.end_offset < 0 || position.end_offset > String.length contents then Ok None
    else
      let prefix = String.sub contents 0 position.end_offset in
      if String.equal (position_of prefix).digest position.digest
      then Ok (Some (parse_with ~keep_history:false ~resolve_subject prefix).articles)
      else Ok None
