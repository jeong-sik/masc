open Keeper_memory_os_types
open Result.Syntax
open Keeper_memory_os_current_types
open Keeper_memory_os_current_layout

let durable_range_id_to_json (range_id : durable_range_id) =
  `Assoc
    [ "schema_version", `Int 2
    ; "unread_messages", Keeper_librarian_unread.list_to_json range_id.unread_messages
    ; "receipt_scope", `String range_id.receipt_scope
    ; "trace_id", `String range_id.trace_id
    ; "history_start_boundary_line", `Int range_id.history_start_boundary_line
    ; "start_atom", `Int range_id.start_atom
    ; "end_atom", `Int range_id.end_atom
    ; "last_atom_digest", `String range_id.last_atom_digest
    ; "end_boundary_line", `Int range_id.end_boundary_line
    ; "boundary_lines_seen", `Int range_id.boundary_lines_seen
    ]
;;

let unread_receipt_fields fields =
  let* version = wire_int_field "schema_version" fields in
  let* () = if version = 2 then Ok ()
    else wire_fail [Wire_field "schema_version"] (Unknown_token (string_of_int version)) in
  let* json = wire_json_field "unread_messages" fields in
  Keeper_librarian_unread.list_of_json json
  |> Result.map_error (fun detail ->
    {path=[Wire_field "unread_messages"];reason=Unknown_token detail})
;;

let durable_range_id_of_json = function
  | `Assoc fields ->
    let* () =
      exact_field_names_result
        [ "schema_version"
        ; "unread_messages"
        ; "receipt_scope"
        ; "trace_id"
        ; "history_start_boundary_line"
        ; "start_atom"
        ; "end_atom"
        ; "last_atom_digest"
        ; "end_boundary_line"
        ; "boundary_lines_seen"
        ]
        fields
    in
    let* unread_messages = unread_receipt_fields fields in
    let* receipt_scope = wire_string_field "receipt_scope" fields in
    let* trace_id = wire_string_field "trace_id" fields in
    let* history_start_boundary_line =
      wire_int_field "history_start_boundary_line" fields
    in
    let* start_atom = wire_int_field "start_atom" fields in
    let* end_atom = wire_int_field "end_atom" fields in
    let* last_atom_digest = wire_string_field "last_atom_digest" fields in
    let* end_boundary_line = wire_int_field "end_boundary_line" fields in
    let* boundary_lines_seen = wire_int_field "boundary_lines_seen" fields in
    let* () =
      if String.equal (String.trim receipt_scope) ""
      then wire_fail [ Wire_field "receipt_scope" ] Blank_string
      else Ok ()
    in
    let* () =
      if String.equal (String.trim trace_id) ""
      then wire_fail [ Wire_field "trace_id" ] Blank_string
      else Ok ()
    in
    let* () =
      if history_start_boundary_line >= 1
      then Ok ()
      else wire_fail [ Wire_field "history_start_boundary_line" ] Not_positive
    in
    let* () =
      if start_atom >= 0
      then Ok ()
      else wire_fail [ Wire_field "start_atom" ] Negative
    in
    let* () =
      if end_atom > start_atom
      then Ok ()
      else wire_fail [ Wire_field "end_atom" ] Not_positive
    in
    let* () =
      if String_util.is_lowercase_sha256_hex last_atom_digest
      then Ok ()
      else wire_fail [ Wire_field "last_atom_digest" ] (Unknown_token last_atom_digest)
    in
    let* () =
      if end_boundary_line >= history_start_boundary_line
      then Ok ()
      else wire_fail [ Wire_field "end_boundary_line" ] Not_positive
    in
    let* () =
      if boundary_lines_seen >= end_boundary_line
      then Ok ()
      else wire_fail [ Wire_field "boundary_lines_seen" ] Not_positive
    in
    let* () = Keeper_librarian_unread.validate_atom_bounds ~trace_id
      ~history_start_boundary_line ~end_atom unread_messages
      |> Result.map_error (fun detail ->
        {path=[Wire_field "unread_messages"];reason=Unknown_token detail}) in
    let* () = if List.for_all (fun (hole : Keeper_librarian_unread.t) ->
      match hole.source with
      | Atom {atom;_} -> atom >= start_atom
      | Official_turn _ -> false) unread_messages then Ok ()
      else wire_fail [Wire_field "unread_messages"] (Unknown_token "unread source precedes receipt interval") in
    Ok { receipt_scope
    ; trace_id
    ; history_start_boundary_line
    ; start_atom
    ; end_atom
    ; last_atom_digest
    ; end_boundary_line
    ; boundary_lines_seen
    ; unread_messages
    }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let official_range_id_to_json (range_id : official_range_id) =
  `Assoc
    [ "schema_version", `Int 2
    ; "unread_messages", Keeper_librarian_unread.list_to_json range_id.unread_messages
    ; "receipt_scope", `String range_id.receipt_scope
    ; "after_boundary_line", `Int range_id.after_boundary_line
    ; "turns", `List (List.map (fun (line, turn_ref) ->
        `Assoc [ "line", `Int line; "turn_ref", Ids.Turn_ref.to_yojson turn_ref ]) range_id.turns)
    ]
;;

let official_range_id_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result
      [ "schema_version"; "unread_messages"; "receipt_scope"; "after_boundary_line"; "turns" ] fields in
    let* unread_messages = unread_receipt_fields fields in
    let* receipt_scope = wire_string_field "receipt_scope" fields in
    let* after_boundary_line = wire_int_field "after_boundary_line" fields in
    let* turns = wire_list_field "turns" fields in
    let* () =
      if String.equal (String.trim receipt_scope) ""
      then wire_fail [ Wire_field "receipt_scope" ] Blank_string
      else if after_boundary_line < 0
      then wire_fail [ Wire_field "after_boundary_line" ] Negative
      else Ok ()
    in
    let rec parse previous index = function
      | [] -> Ok []
      | json :: rest ->
        let* line, turn_ref =
          wire_at (Wire_field "turns") (wire_at (Wire_index index)
            (match json with
             | `Assoc row ->
               let* () = exact_field_names_result [ "line"; "turn_ref" ] row in
               let* line = wire_int_field "line" row in
               let* text = wire_string_field "turn_ref" row in
               let* turn_ref =
                 match Ids.Turn_ref.of_string text with
                 | Some value -> Ok value
                 | None -> wire_fail [ Wire_field "turn_ref" ] (Unknown_token text)
               in
               if line <= previous
               then wire_fail [ Wire_field "line" ] Not_ascending
               else Ok (line, turn_ref)
             | _ -> wire_here Expected_object))
        in
        let+ rest = parse line (index + 1) rest in
        (line, turn_ref) :: rest
    in
    let* turns =
      match turns with
      | [] -> wire_fail [ Wire_field "turns" ] Empty_list
      | _ :: _ -> parse after_boundary_line 0 turns
    in
    let* () = if List.for_all (fun (hole : Keeper_librarian_unread.t) ->
      match hole.source with
      | Official_turn {turn_ref;boundary_line;_} ->
        List.exists (fun (line, selected_turn) ->
          line = boundary_line && Ids.Turn_ref.equal selected_turn turn_ref) turns
      | Atom _ -> false) unread_messages then Ok ()
      else wire_fail [Wire_field "unread_messages"] (Unknown_token "unread source is not a selected official turn") in
    Ok { receipt_scope; after_boundary_line; turns; unread_messages }
  | _ -> wire_here Expected_object
;;

let explicit_candidate_id_to_json (candidate : explicit_candidate_id) =
  `Assoc ["queue_generation", `String candidate.queue_generation;
          "request_id", `String candidate.request_id;
          "sequence", `Int candidate.sequence;
          "input_sha256", `String candidate.input_sha256]
;;

let explicit_candidate_id_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result
      ["queue_generation"; "request_id"; "sequence"; "input_sha256"] fields in
    let canonical field =
      let* value = wire_string_field field fields in
      if String.trim value = "" then wire_fail [Wire_field field] Blank_string
      else if String.trim value <> value then wire_fail [Wire_field field] (Unknown_token value)
      else Ok value in
    let* queue_generation = canonical "queue_generation" in
    let* request_id = canonical "request_id" in
    let* sequence = wire_int_field "sequence" fields in
    let* () = if sequence > 0 then Ok () else wire_fail [Wire_field "sequence"] Not_positive in
    let* input_sha256 = wire_string_field "input_sha256" fields in
    let+ () = if String_util.is_lowercase_sha256_hex input_sha256 then Ok ()
      else wire_fail [Wire_field "input_sha256"] (Unknown_token input_sha256) in
    {queue_generation; request_id; sequence; input_sha256}
  | _ -> wire_here Expected_object
;;

let admission_recall_binding_to_json binding =
  `Assoc ["candidate_id", explicit_candidate_id_to_json binding.candidate_id;
          "source_fact", fact_to_json binding.source_fact;
          "target_memory_id", `String binding.target_memory_id]
;;

let admission_recall_binding_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result ["candidate_id"; "source_fact"; "target_memory_id"] fields in
    let* candidate_json = wire_json_field "candidate_id" fields in
    let* candidate_id = wire_at (Wire_field "candidate_id") (explicit_candidate_id_of_json candidate_json) in
    let* source_json = wire_json_field "source_fact" fields in
    let* source_fact = wire_at (Wire_field "source_fact") (fact_of_json source_json) in
    let* target_memory_id = wire_string_field "target_memory_id" fields in
    let* () = if is_memory_id target_memory_id then Ok ()
      else wire_fail [Wire_field "target_memory_id"] (Unknown_token target_memory_id) in
    let row = `Assoc ["sequence", `Int candidate_id.sequence;
      "request_id", `String candidate_id.request_id; "fact", fact_to_json source_fact] in
    let digest = Agent_core_sha256.(digest_string (Yojson.Safe.to_string row) |> to_hex) in
    let+ () = if String.equal digest candidate_id.input_sha256 then Ok ()
      else wire_fail [Wire_field "source_fact"] (Unknown_token "candidate payload digest mismatch") in
    {candidate_id; source_fact; target_memory_id}
  | _ -> wire_here Expected_object
;;

let consumed_candidate = function
  | Explicit_candidate candidate -> Some candidate
  | Explicit_candidate_with_recall binding -> Some binding.candidate_id
  | Atom_range _ | Official_range _ -> None
;;

module Candidate_request_set = Set.Make (struct
    type t = string * string

    let compare (gen_a, req_a) (gen_b, req_b) =
      let cmp = String.compare gen_a gen_b in
      if cmp <> 0 then cmp else String.compare req_a req_b
  end)

module Candidate_sequence_set = Set.Make (struct
    type t = string * int

    let compare (gen_a, seq_a) (gen_b, seq_b) =
      let cmp = String.compare gen_a gen_b in
      if cmp <> 0 then cmp else Int.compare seq_a seq_b
  end)

(* Identity coordinates, not payload equality, determine whether an input was
   consumed. A changed digest or moved sequence never makes a reused ID new. *)
let validate_unique_explicit_candidates candidates =
  let rec loop requests sequences = function
    | [] -> Ok ()
    | (candidate : explicit_candidate_id) :: rest ->
      let request = candidate.queue_generation, candidate.request_id in
      let sequence = candidate.queue_generation, candidate.sequence in
      if Candidate_request_set.mem request requests
         || Candidate_sequence_set.mem sequence sequences
      then
        Error
          (Printf.sprintf
             "explicit candidate identity conflict generation=%s request_id=%s sequence=%d"
             candidate.queue_generation candidate.request_id candidate.sequence)
      else
        loop
          (Candidate_request_set.add request requests)
          (Candidate_sequence_set.add sequence sequences)
          rest
  in
  loop Candidate_request_set.empty Candidate_sequence_set.empty candidates
;;

(* Each source kind names its own mutually exclusive receipt identity field. *)
let consumed_range_field = function
  | Atom_range range -> "range_id", durable_range_id_to_json range
  | Official_range range -> "official_range_id", official_range_id_to_json range
  | Explicit_candidate candidate -> "explicit_candidate_id", explicit_candidate_id_to_json candidate
  | Explicit_candidate_with_recall binding -> "admission_recall_binding", admission_recall_binding_to_json binding
;;

let durable_range_receipt_to_json = function
  | Prepared { range_id; snapshot_revision; snapshot_sha256 } ->
    `Assoc
      [ "state", `String "prepared"
      ; consumed_range_field range_id
      ; "snapshot_revision", `Int snapshot_revision
      ; "snapshot_sha256", `String snapshot_sha256
      ]
  | Committed { range_id; snapshot_revision; snapshot_sha256 } ->
    `Assoc
      [ "state", `String "committed"
      ; consumed_range_field range_id
      ; "snapshot_revision", `Int snapshot_revision
      ; "snapshot_sha256", `String snapshot_sha256
      ]
;;

let durable_range_receipt_of_json = function
  | `Assoc fields ->
    let* range_id =
      let decode key parse wrap =
        let* () = exact_field_names_result
          [ "state"; key; "snapshot_revision"; "snapshot_sha256" ] fields in
        let* json = wire_json_field key fields in
        Result.map wrap (wire_at (Wire_field key) (parse json))
      in
      let keys = ["range_id"; "official_range_id"; "explicit_candidate_id"; "admission_recall_binding"] in
      match List.filter (fun key -> List.mem_assoc key fields) keys with
      | ["range_id"] -> decode "range_id" durable_range_id_of_json (fun range -> Atom_range range)
      | ["official_range_id"] -> decode "official_range_id" official_range_id_of_json (fun range -> Official_range range)
      | ["explicit_candidate_id"] -> decode "explicit_candidate_id" explicit_candidate_id_of_json
          (fun candidate -> Explicit_candidate candidate)
      | ["admission_recall_binding"] -> decode "admission_recall_binding" admission_recall_binding_of_json
          (fun binding -> Explicit_candidate_with_recall binding)
      | [] -> wire_here (Field_set_mismatch {missing=keys; unexpected=[]})
      | conflicting -> wire_here (Field_set_mismatch {missing=[]; unexpected=conflicting})
    in
    let* state = wire_string_field "state" fields in
    let* snapshot_revision = wire_int_field "snapshot_revision" fields in
    let* () =
      if snapshot_revision >= 1
      then Ok ()
      else wire_fail [ Wire_field "snapshot_revision" ] Not_positive
    in
    let* snapshot_sha256 = wire_string_field "snapshot_sha256" fields in
    let* () =
      if String_util.is_lowercase_sha256_hex snapshot_sha256
      then Ok ()
      else wire_fail [ Wire_field "snapshot_sha256" ] (Unknown_token snapshot_sha256)
    in
    (match state with
     | "prepared" -> Ok (Prepared { range_id; snapshot_revision; snapshot_sha256 })
     | "committed" -> Ok (Committed { range_id; snapshot_revision; snapshot_sha256 })
     | unknown -> wire_fail [ Wire_field "state" ] (Unknown_token unknown))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let durable_range_receipts_to_json receipts =
  `Assoc [ "receipts", `List (List.map durable_range_receipt_to_json receipts) ]
;;

(* A receipt entry this binary cannot decode: legacy bytes from a schema it
   no longer writes. One such entry used to wedge the whole ledger: every
   pass failed the file and continuity never advanced, which is how a
   pre-#42020 [explicit_write_range_id] entry froze five keepers'
   snapshots and grew their carried ranges until fresh sessions failed
   (#42597). A receipt is evidence for skipping already-committed work, so
   an unverifiable receipt reads as no receipt, never as an honored one
   (#32461); the skipped bytes move aside with their reason instead of
   being silently dropped. *)
type skipped_range_receipt =
  { index : int
  ; reason : string
  ; entry : Yojson.Safe.t
  }

let durable_range_receipts_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result [ "receipts" ] fields in
    let* receipts = wire_list_field "receipts" fields in
    let decoded, skipped =
      List.fold_left
        (fun (ok, skipped) (index, json) ->
           match durable_range_receipt_of_json json with
           | Ok receipt -> receipt :: ok, skipped
           | Error error ->
             ( ok
             , { index; reason = wire_error_to_string error; entry = json }
               :: skipped ))
        ([], [])
        (List.mapi (fun index json -> index, json) receipts)
    in
    let decoded = List.rev decoded in
    let candidates = List.filter_map (function
      | Prepared {range_id; _} | Committed {range_id; _} -> consumed_candidate range_id) decoded in
    let+ () = validate_unique_explicit_candidates candidates
      |> Result.map_error (fun detail ->
        {path=[Wire_field "receipts"]; reason=Unknown_token detail}) in
    decoded, List.rev skipped
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

(* How many times this process decoded sidecar bytes. A read answered from
   [durable_range_receipt_cache] below does not count. *)
let durable_range_receipt_decodes = Atomic.make 0

let read_durable_range_receipts ~keepers_dir ~keeper_id =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> Ok ([], [])
  | Some content ->
    Atomic.incr durable_range_receipt_decodes;
    (match Yojson.Safe.from_string content with
     | json ->
       durable_range_receipts_of_json json
       |> Result.map_error (fun error ->
         Printf.sprintf
           "durable Librarian range receipt rejected path=%s: %s"
           path
           (wire_error_to_string error))
     | exception Yojson.Json_error message ->
       Error
         (Printf.sprintf
            "durable Librarian range receipt is not JSON path=%s: %s"
            path
            message))
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error
      (Printf.sprintf
         "durable Librarian range receipt unreadable path=%s: %s"
         path
         (Printexc.to_string exn))
;;

let validate_durable_range_receipts ~keepers_dir ~keeper_id =
  (* The read is the validation. Skipped entries keep the row invalid until
     the consume path quarantines them and rewrites the file without them,
     so the audit keeps pointing at legacy bytes while they are still on
     disk. This audit never heals: it only reports. *)
  match read_durable_range_receipts ~keepers_dir ~keeper_id with
  | Error _ as error -> error
  | Ok (_, []) -> Ok ()
  | Ok (_, skipped) ->
    Error
      (Printf.sprintf
         "durable Librarian range receipt holds %d unreadable entries path=%s"
         (List.length skipped)
         (durable_range_receipt_path ~keepers_dir ~keeper_id))
;;
