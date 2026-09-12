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
    "the ledger does not end at a line boundary"
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
    | Fs_compat.Private_file_failed error
    | Fs_compat.Private_file_failed_with_cleanup_failure { error; _ } ->
      Error (Write_failed { path; detail = append_failure_detail error }))

type rejected_line = {
  line_number : int;
  detail : string;
}

type ledger = {
  end_offset : int;
  articles : World_constitution_types.t list;
  rejected : rejected_line list;
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

(* Folding keeps the order a world wrote its norms in. Re-adding an article
   that is still held replaces it in place, because that is an edit; re-adding
   one that was removed puts it at the end, because the world changed its mind
   and that is when it did. *)
let apply held = function
  | World_constitution_types.Added article ->
    if List.exists (same_id article.id) held then
      List.map
        (fun existing -> if same_id article.id existing then article else existing)
        held
    else held @ [ article ]
  | World_constitution_types.Removed { id; _ } ->
    List.filter (fun existing -> not (same_id id existing)) held

let parse contents =
  let end_offset = String.length contents in
  let rec scan line_number held rejected = function
    | [] -> { end_offset; articles = held; rejected = List.rev rejected }
    | line :: rest ->
      if String.equal (String.trim line) "" then
        scan (line_number + 1) held rejected rest
      else (
        let reject detail =
          scan (line_number + 1) held ({ line_number; detail } :: rejected) rest
        in
        match Yojson.Safe.from_string line with
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception exn -> reject (Printexc.to_string exn)
        | json -> (
          match World_constitution_wire.entry_of_json json with
          | Error error ->
            reject (World_constitution_wire.decode_error_to_string error)
          | Ok entry -> scan (line_number + 1) (apply held entry) rejected rest))
  in
  scan 1 [] [] (String.split_on_char '\n' contents)

let load ~base_path =
  let path = ledger_path ~base_path in
  match Fs_compat.load_file_opt path with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Unreadable { path; detail = Printexc.to_string exn })
  | None -> Ok { end_offset = 0; articles = []; rejected = [] }
  | Some contents -> Ok (parse contents)
