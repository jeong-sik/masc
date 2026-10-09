(** Keeper-owned current Memory OS snapshot. *)

open Keeper_memory_os_types
open Result.Syntax

let suffix = ".memory-current.json"

include Keeper_memory_os_current_types
open Keeper_memory_os_support_core

let upsert_error_to_string = function
  | Unsupported_derivation invalidation ->
    Printf.sprintf
      "derived Memory OS fact has no complete support path memory_id=%s missing_premise_ids=%s"
      (memory_id invalidation.fact)
      (String.concat "," invalidation.missing_premise_ids)
  | Upsert_persistence_failed detail -> detail
;;

let merge_basis = Keeper_memory_os_support_core.merge_basis

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

let journal_suffix = ".memory-journal.jsonl"

let journal_path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ journal_suffix)
;;

let durable_range_receipt_suffix = ".librarian-range-commit.json"

let durable_range_receipt_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ durable_range_receipt_suffix)
;;

let retraction_plan_receipt_suffix = ".memory-retraction-plan.json"

let retraction_plan_receipt_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ retraction_plan_receipt_suffix)
;;

type durable_range_id =
  { receipt_scope : string
  ; trace_id : string
  ; history_start_boundary_line : int
  ; start_atom : int
  ; end_atom : int
  ; last_atom_digest : string
  ; end_boundary_line : int
  ; boundary_lines_seen : int
  }

type official_range_id =
  { receipt_scope : string
  ; after_boundary_line : int
  ; turns : (int * Ids.Turn_ref.t) list
  }

type explicit_candidate_id =
  { queue_generation : string
  ; request_id : string
  ; sequence : int
  ; input_sha256 : string
  }

type admission_recall_binding =
  { candidate_id : explicit_candidate_id
  ; source_fact : fact
  ; target_memory_id : string
  }

type admission_recall =
  { decided_at_revision : int option
  ; bindings : admission_recall_binding list
  }

type consumed_range =
  | Atom_range of durable_range_id
  | Official_range of official_range_id
  | Explicit_candidate of explicit_candidate_id
  | Explicit_candidate_with_recall of admission_recall_binding

type durable_range_receipt =
  | Prepared of
      { range_id : consumed_range
      ; snapshot_revision : int
      ; snapshot_sha256 : string
      }
  | Committed of
      { range_id : consumed_range
      ; snapshot_revision : int
      ; snapshot_sha256 : string
      }

let durable_range_id_to_json (range_id : durable_range_id) =
  `Assoc
    [ "receipt_scope", `String range_id.receipt_scope
    ; "trace_id", `String range_id.trace_id
    ; "history_start_boundary_line", `Int range_id.history_start_boundary_line
    ; "start_atom", `Int range_id.start_atom
    ; "end_atom", `Int range_id.end_atom
    ; "last_atom_digest", `String range_id.last_atom_digest
    ; "end_boundary_line", `Int range_id.end_boundary_line
    ; "boundary_lines_seen", `Int range_id.boundary_lines_seen
    ]
;;

let durable_range_id_of_json = function
  | `Assoc fields ->
    let* () =
      exact_field_names_result
        [ "receipt_scope"
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
    let+ () =
      if boundary_lines_seen >= end_boundary_line
      then Ok ()
      else wire_fail [ Wire_field "boundary_lines_seen" ] Not_positive
    in
    { receipt_scope
    ; trace_id
    ; history_start_boundary_line
    ; start_atom
    ; end_atom
    ; last_atom_digest
    ; end_boundary_line
    ; boundary_lines_seen
    }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let official_range_id_to_json (range_id : official_range_id) =
  `Assoc
    [ "receipt_scope", `String range_id.receipt_scope
    ; "after_boundary_line", `Int range_id.after_boundary_line
    ; "turns", `List (List.map (fun (line, turn_ref) ->
        `Assoc [ "line", `Int line; "turn_ref", Ids.Turn_ref.to_yojson turn_ref ]) range_id.turns)
    ]
;;

let official_range_id_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result [ "receipt_scope"; "after_boundary_line"; "turns" ] fields in
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
    Ok { receipt_scope; after_boundary_line; turns }
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
    let digest = Digestif.SHA256.(digest_string (Yojson.Safe.to_string row) |> to_hex) in
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

(* Identity coordinates, not payload equality, determine whether an input was
   consumed. A changed digest or moved sequence never makes a reused ID new. *)
let validate_unique_explicit_candidates candidates =
  let requests = Hashtbl.create 16 and sequences = Hashtbl.create 16 in
  List.fold_left (fun result (candidate : explicit_candidate_id) ->
    let* () = result in
    let request = candidate.queue_generation, candidate.request_id in
    let sequence = candidate.queue_generation, candidate.sequence in
    if Hashtbl.mem requests request || Hashtbl.mem sequences sequence then
      Error (Printf.sprintf "explicit candidate identity conflict generation=%s request_id=%s sequence=%d"
        candidate.queue_generation candidate.request_id candidate.sequence)
    else (
      Hashtbl.add requests request ();
      Hashtbl.add sequences sequence ();
      Ok ())) (Ok ()) candidates
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

let durable_range_receipts_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result [ "receipts" ] fields in
    let* receipts = wire_list_field "receipts" fields in
    let* decoded = List.fold_right
      (fun json accumulated ->
         let* accumulated = accumulated in
         let+ receipt = durable_range_receipt_of_json json in
         receipt :: accumulated)
      receipts (Ok []) in
    let candidates = List.filter_map (function
      | Prepared {range_id; _} | Committed {range_id; _} -> consumed_candidate range_id) decoded in
    let+ () = validate_unique_explicit_candidates candidates
      |> Result.map_error (fun detail ->
        {path=[Wire_field "receipts"]; reason=Unknown_token detail}) in
    decoded
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

(* How many times this process decoded sidecar bytes. A read answered from
   [durable_range_receipt_cache] below does not count. *)
let durable_range_receipt_decodes = Atomic.make 0

let read_durable_range_receipts ~keepers_dir ~keeper_id =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> Ok []
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
  (* See read_durable_range_receipts: the read is the validation; the receipt value is intentionally discarded. *)
  read_durable_range_receipts ~keepers_dir ~keeper_id |> Result.map ignore
;;

(* Same regular file with the same size and timestamps. An atomic replace
   gives the path a new inode, and every change to a file's bytes or metadata
   sets its ctime, which user space cannot set back. *)
let same_file_identity a b =
  a.Unix.st_kind = Unix.S_REG && b.Unix.st_kind = Unix.S_REG
  && a.Unix.st_dev = b.Unix.st_dev && a.Unix.st_ino = b.Unix.st_ino
  && a.Unix.st_size = b.Unix.st_size && a.Unix.st_mtime = b.Unix.st_mtime
  && a.Unix.st_ctime = b.Unix.st_ctime

module Path_map = Map.Make (String)

(* A reconcile against the snapshot at [fixed_revision] whose bytes hash to
   [fixed_snapshot_sha256] returned the cached receipts unchanged. *)
type receipt_fixed_point =
  { fixed_revision : int
  ; fixed_snapshot_sha256 : string
  }

(* [receipts] is the result of [read_durable_range_receipts] for the file
   [receipt_identity] describes: the same decode and the same validation. *)
type durable_range_receipt_cache_entry =
  { receipt_identity : Unix.stats
  ; receipts : durable_range_receipt list
  ; fixed_point : receipt_fixed_point option
  }

(* Keyed by sidecar path. Entries are immutable and replaced by compare-and-set,
   so a reader on any domain sees a whole entry or none. *)
let durable_range_receipt_cache : durable_range_receipt_cache_entry Path_map.t Atomic.t =
  Atomic.make Path_map.empty

let rec update_durable_range_receipt_cache path f =
  let before = Atomic.get durable_range_receipt_cache in
  let after = Path_map.update path f before in
  if not (Atomic.compare_and_set durable_range_receipt_cache before after)
  then update_durable_range_receipt_cache path f
;;

let forget_durable_range_receipts path =
  update_durable_range_receipt_cache path
    (fun (_ : durable_range_receipt_cache_entry option) -> None)
;;

(* File timestamps are no coarser than one second on the filesystems masc runs
   on (HFS+ stores whole seconds; APFS and ext4 store nanoseconds at kernel
   clock-tick resolution). A file whose ctime is further than this behind the
   clock therefore cannot change again without its ctime changing. A file
   changed more recently is decoded on every read: a second change within the
   same timestamp tick can keep every field [same_file_identity] compares. *)
let receipt_identity_settle_seconds = 1.0

let inspect_receipt_file path =
  match Unix.lstat path with
  | stats -> Some stats
  | exception Unix.Unix_error ((_ : Unix.error), (_ : string), (_ : string)) -> None
;;

type durable_range_receipt_read =
  | Cached_receipts of durable_range_receipt_cache_entry
  | Uncached_receipts of durable_range_receipt list

(* A cached entry answers only while the file still has the identity it had
   when it was decoded. An entry is published only when the file kept one
   identity across the decode and its ctime was already settled when the read
   began, so every later change to the file gives it an identity the entry
   does not match. A missing, non-regular, recently changed, or concurrently
   changed file is decoded on every read. *)
let read_durable_range_receipts_cached ~keepers_dir ~keeper_id =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  let started = Unix.gettimeofday () in
  let before = inspect_receipt_file path in
  match before, Path_map.find_opt path (Atomic.get durable_range_receipt_cache) with
  | Some current, Some cached when same_file_identity cached.receipt_identity current ->
    Ok (Cached_receipts cached)
  | (Some _ | None), (Some _ | None) ->
    forget_durable_range_receipts path;
    let* receipts = read_durable_range_receipts ~keepers_dir ~keeper_id in
    (match before, inspect_receipt_file path with
     | Some before, Some after
       when same_file_identity before after
            && started -. before.Unix.st_ctime > receipt_identity_settle_seconds ->
       let entry = { receipt_identity = after; receipts; fixed_point = None } in
       update_durable_range_receipt_cache path
         (fun (_ : durable_range_receipt_cache_entry option) -> Some entry);
       Ok (Cached_receipts entry)
     | (Some _ | None), (Some _ | None) -> Ok (Uncached_receipts receipts))
;;

let mark_receipt_fixed_point ~keepers_dir ~keeper_id entry fixed_point =
  update_durable_range_receipt_cache
    (durable_range_receipt_path ~keepers_dir ~keeper_id)
    (function
      | Some current when current == entry -> Some { entry with fixed_point = Some fixed_point }
      | (Some _ | None) as unchanged -> unchanged)
;;

(* The replaced file already has a new identity; dropping the entry also covers
   a write that reports failure after the replace. *)
let write_durable_range_receipts ~keepers_dir ~keeper_id receipts =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  let written =
    Fs_compat.save_file_atomic_strict path
      (Yojson.Safe.to_string (durable_range_receipts_to_json receipts))
  in
  forget_durable_range_receipts path;
  written
  |> Result.map_error (fun message ->
    Printf.sprintf
      "durable Librarian range receipt write failed path=%s: %s"
      path
      message)
;;

let remove_durable_range_receipts ~keepers_dir ~keeper_id =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  let removed =
    match Sys.remove path with
    | () -> Ok ()
    | exception Sys_error _ when not (Sys.file_exists path) -> Ok ()
    | exception exn -> (* cancel-guard-ok: Sys.remove performs no Eio operation, so Cancelled cannot originate in this body. *)
      Error
        (Printf.sprintf
           "durable Librarian range receipt removal failed path=%s: %s"
           path
           (Printexc.to_string exn))
  in
  forget_durable_range_receipts path;
  removed
;;

let sha256 content = Digestif.SHA256.(digest_string content |> to_hex)

let receipt_range_id = function
  | Prepared { range_id; _ } | Committed { range_id; _ } -> range_id
;;

let range_key = function
  | Atom_range range -> range.receipt_scope, `Atom
  | Official_range range -> range.receipt_scope, `Official
  | Explicit_candidate candidate -> candidate.queue_generation, `Explicit_candidate candidate.request_id
  | Explicit_candidate_with_recall binding ->
    binding.candidate_id.queue_generation, `Explicit_candidate binding.candidate_id.request_id
;;

let upsert_durable_range_receipt receipts receipt =
  let key = range_key (receipt_range_id receipt) in
  receipt :: List.filter (fun prior ->
    range_key (receipt_range_id prior) <> key
    || (match receipt, prior with
        | Prepared _, Committed _ -> true
        | Prepared _, Prepared _ | Committed _, _ -> false)) receipts
;;

let reconcile_durable_range_receipts
      ~keepers_dir
      ~keeper_id
      ~snapshot
  =
  (* The snapshot is hashed at most once per pass, and only when a receipt or
     the cached fixed point names its revision. *)
  let snapshot =
    Option.map (fun (current, content) -> current, lazy (sha256 content)) snapshot
  in
  let* read = read_durable_range_receipts_cached ~keepers_dir ~keeper_id in
  let receipts, cached =
    match read with
    | Cached_receipts entry -> entry.receipts, Some entry
    | Uncached_receipts receipts -> receipts, None
  in
  (* A reconcile that returned the receipts unchanged at revision R with bytes S
     kept every receipt: each was committed, their keys were distinct, and each
     named a revision below R, or R with S. The snapshot at R with S is the
     same input. A snapshot above R keeps every receipt through the
     [current.revision > snapshot_revision] arm below, so the result is
     unchanged again. A missing snapshot, a lower revision, or R with other
     bytes runs the full reconcile. *)
  let covered =
    match cached, snapshot with
    | Some { fixed_point = Some fixed; _ }, Some (current, digest) ->
      current.revision > fixed.fixed_revision
      || (Int.equal current.revision fixed.fixed_revision
          && String.equal (Lazy.force digest) fixed.fixed_snapshot_sha256)
    | Some { fixed_point = Some _; _ }, None
    | Some { fixed_point = None; _ }, (Some _ | None)
    | None, (Some _ | None) -> false
  in
  if covered then Ok receipts
  else
    let seen = Hashtbl.create 16 in
    let reconciled =
      List.filter_map
        (function
          | Prepared { range_id; snapshot_revision; snapshot_sha256 } ->
            (match snapshot with
             | Some (current, digest)
               when Int.equal current.revision snapshot_revision
                    && String.equal (Lazy.force digest) snapshot_sha256 ->
               Some (Committed { range_id; snapshot_revision; snapshot_sha256 })
             | None | Some _ -> None)
          | Committed ({ snapshot_revision; snapshot_sha256; _ } as committed) ->
            (match snapshot with
             | Some (current, _digest) when current.revision > snapshot_revision ->
               Some (Committed committed)
             | Some (current, digest)
               when Int.equal current.revision snapshot_revision
                    && String.equal (Lazy.force digest) snapshot_sha256 ->
               Some (Committed committed)
             | None | Some _ -> None))
        receipts
      |> List.fold_left (fun kept receipt ->
           let key = range_key (receipt_range_id receipt) in
           if Hashtbl.mem seen key then kept
           else (Hashtbl.add seen key (); receipt :: kept)) []
      |> List.rev
    in
    if receipts = reconciled
    then (
      (match cached, snapshot with
       | Some entry, Some (current, digest) ->
         mark_receipt_fixed_point ~keepers_dir ~keeper_id entry
           { fixed_revision = current.revision; fixed_snapshot_sha256 = Lazy.force digest }
       | Some _, None | None, (Some _ | None) -> ());
      Ok reconciled)
    else if reconciled = []
    then
      let+ () = remove_durable_range_receipts ~keepers_dir ~keeper_id in
      []
    else
      let+ () = write_durable_range_receipts ~keepers_dir ~keeper_id reconciled in
      reconciled
;;

let keeper_id_of_filename filename = Filename.chop_suffix_opt ~suffix filename
;;

let list_keeper_ids_for_keepers_dir ~keepers_dir =
  if not (Sys.file_exists keepers_dir && Sys.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map keeper_id_of_filename
    |> List.sort String.compare
;;

let list_durable_range_receipt_keeper_ids ~keepers_dir =
  if not (Sys.file_exists keepers_dir && Sys.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map (Filename.chop_suffix_opt ~suffix:durable_range_receipt_suffix)
    |> List.sort String.compare
;;

(* Wire keys of the snapshot document. The encoder writes them and the decoder
   both reads them and names them in a rejection, so a typo would otherwise
   have to be made identically in three places to be caught. *)
let field_revision = "revision"
let field_updated_at = "updated_at"
let field_source = "source"
let field_facts = "facts"
let field_change = "change"
let field_kind = "kind"
let field_trace_id = "trace_id"
let field_added = "added"
let field_removed = "removed"
let field_retained = "retained"
let field_invalidated = "invalidated"
let field_fact = "fact"
let field_missing_premise_ids = "missing_premise_ids"

let source_kind_to_string = function
  | Librarian -> "librarian"
  | Explicit_write -> "explicit_write"
  | Explicit_retract -> "explicit_retract"
;;

let source_kind_of_string = function
  | "librarian" -> Some Librarian
  | "explicit_write" -> Some Explicit_write
  | "explicit_retract" -> Some Explicit_retract
  | _ -> None
;;

let exact_object_fields required fields =
  List.length required = List.length fields
  && List.for_all
       (fun required_name ->
          match
            List.filter
              (fun (observed_name, _) ->
                 String.equal required_name observed_name)
              fields
          with
          | [ _ ] -> true
          | [] | _ :: _ :: _ -> false)
       required
;;

let source_to_json source =
  `Assoc
    [ field_kind, `String (source_kind_to_string source.kind)
    ; field_trace_id, `String source.trace_id
    ]
;;

let source_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result [ field_kind; field_trace_id ] fields in
    let* kind_token = wire_string_field field_kind fields in
    let* trace_id = wire_string_field field_trace_id fields in
    let* kind =
      match source_kind_of_string kind_token with
      | Some kind -> Ok kind
      | None -> wire_fail [ Wire_field field_kind ] (Unknown_token kind_token)
    in
    let+ () =
      if String.equal (String.trim trace_id) ""
      then wire_fail [ Wire_field field_trace_id ] Blank_string
      else Ok ()
    in
    { kind; trace_id }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

(* Paths are relative to the array itself: this decodes [facts],
   [change.added], and [change.removed], and each caller places the result. *)
let facts_of_json = function
  | `List values ->
    let rec loop index seen acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* fact = wire_at (Wire_index index) (fact_of_json value) in
        let identity = memory_id fact in
        if Set_util.StringSet.mem identity seen
        then wire_fail [ Wire_index index ] (Duplicate_entry identity)
        else
          loop (index + 1) (Set_util.StringSet.add identity seen) (fact :: acc) rest
    in
    loop 0 Set_util.StringSet.empty [] values
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ ->
    wire_here Expected_array
;;

let facts_to_json facts =
  `List (List.map fact_to_json facts)
;;

let support_invalidation_to_json invalidation =
  let missing_premise_ids = invalidation.missing_premise_ids in
  if
    missing_premise_ids = []
    || not (List.for_all Keeper_memory_os_types.is_memory_id missing_premise_ids)
    || not
         (List.equal
            String.equal
            missing_premise_ids
            (List.sort_uniq String.compare missing_premise_ids))
  then invalid_arg "support invalidation must carry canonical missing premise identities";
  `Assoc
    [ field_fact, fact_to_json invalidation.fact
    ; ( field_missing_premise_ids
      , `List
          (List.map
             (fun premise_id -> `String premise_id)
             invalidation.missing_premise_ids) )
    ]
;;

let support_invalidation_of_json = function
  | `Assoc fields ->
    let* () =
      exact_field_names_result [ field_fact; field_missing_premise_ids ] fields
    in
    let* fact_json = wire_json_field field_fact fields in
    let* premise_values = wire_list_field field_missing_premise_ids fields in
    let* fact = wire_at (Wire_field field_fact) (fact_of_json fact_json) in
    let rec premise_ids index previous acc = function
      | [] -> Ok (List.rev acc)
      | `String premise_id :: rest ->
        let at reason =
          wire_fail [ Wire_field field_missing_premise_ids; Wire_index index ] reason
        in
        if not (Keeper_memory_os_types.is_memory_id premise_id)
        then at (Not_a_memory_id premise_id)
        else (
          match previous with
          | Some previous when String.compare previous premise_id >= 0 ->
            at Not_ascending
          | Some _ | None ->
            premise_ids (index + 1) (Some premise_id) (premise_id :: acc) rest)
      | _ :: _ ->
        wire_fail
          [ Wire_field field_missing_premise_ids; Wire_index index ]
          Expected_string
    in
    let* missing_premise_ids = premise_ids 0 None [] premise_values in
    (match missing_premise_ids with
     | [] -> wire_fail [ Wire_field field_missing_premise_ids ] Empty_list
     | _ :: _ -> Ok { fact; missing_premise_ids })
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let change_to_json change =
  `Assoc
    [ field_added, facts_to_json change.added
    ; field_removed, facts_to_json change.removed
    ; field_retained, `Int change.retained
    ; ( field_invalidated
      , `List (List.map support_invalidation_to_json change.invalidated) )
    ]
;;

let change_of_json = function
  | `Assoc fields ->
    let* () =
      exact_field_names_result
        [ field_added; field_removed; field_retained; field_invalidated ]
        fields
    in
    let* added_json = wire_json_field field_added fields in
    let* removed_json = wire_json_field field_removed fields in
    let* retained = wire_int_field field_retained fields in
    let* invalidated_json = wire_list_field field_invalidated fields in
    let* added = wire_at (Wire_field field_added) (facts_of_json added_json) in
    let* removed = wire_at (Wire_field field_removed) (facts_of_json removed_json) in
    let rec invalidations index seen acc = function
      | [] -> Ok (List.rev acc)
      | json :: rest ->
        let* invalidation =
          wire_at_element field_invalidated index (support_invalidation_of_json json)
        in
        let identity = memory_id invalidation.fact in
        if Set_util.StringSet.mem identity seen
        then
          wire_fail
            [ Wire_field field_invalidated; Wire_index index ]
            (Duplicate_entry identity)
        else
          invalidations
            (index + 1)
            (Set_util.StringSet.add identity seen)
            (invalidation :: acc)
            rest
    in
    let* invalidated = invalidations 0 Set_util.StringSet.empty [] invalidated_json in
    let+ () =
      if retained >= 0
      then Ok ()
      else wire_fail [ Wire_field field_retained ] Negative
    in
    { added; removed; retained; invalidated }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

(** A snapshot whose parts each decoded but do not agree with each other.
    Separate from {!Keeper_memory_os_types.wire_error} because nothing here is
    a JSON shape problem: the document is well formed and its own [change] does
    not describe its own [facts]. Closed, so a new consistency rule has to name
    itself before it can refuse a file that is already on disk. *)
type snapshot_inconsistency =
  | Stored_rows_are_unsupported of string list
      (** Rows whose derivation premises are absent from the maintained fixed
          point, so support maintenance would not have kept them. *)
  | Added_row_is_not_current of string
  | Removed_row_is_still_current of string
  | Invalidated_row_is_current of string
  | Invalidated_row_is_observed of string
  | Invalidated_row_is_still_supported of string
  | Invalidated_premises_do_not_match of string
  | Retained_does_not_add_up of
      { retained : int
      ; added : int
      ; facts : int
      }

type snapshot_rejection =
  | Snapshot_undecodable of Keeper_memory_os_types.wire_error
  | Snapshot_inconsistent of snapshot_inconsistency

let snapshot_inconsistency_to_string = function
  | Stored_rows_are_unsupported memory_ids ->
    Printf.sprintf
      "%s: %s no longer has a complete support path"
      field_facts
      (String.concat "," memory_ids)
  | Added_row_is_not_current memory_id ->
    Printf.sprintf
      "%s.%s: %s is not the row %s currently holds"
      field_change
      field_added
      memory_id
      field_facts
  | Removed_row_is_still_current memory_id ->
    Printf.sprintf
      "%s.%s: %s is still the row %s currently holds"
      field_change
      field_removed
      memory_id
      field_facts
  | Invalidated_row_is_current memory_id ->
    Printf.sprintf
      "%s.%s: %s is still in %s"
      field_change
      field_invalidated
      memory_id
      field_facts
  | Invalidated_row_is_observed memory_id ->
    Printf.sprintf
      "%s.%s: %s is observed, so it has no support to lose"
      field_change
      field_invalidated
      memory_id
  | Invalidated_row_is_still_supported memory_id ->
    Printf.sprintf
      "%s.%s: %s still has a complete support path"
      field_change
      field_invalidated
      memory_id
  | Invalidated_premises_do_not_match memory_id ->
    Printf.sprintf
      "%s.%s: %s names premises other than the ones missing from the maintained fixed point"
      field_change
      field_invalidated
      memory_id
  | Retained_does_not_add_up { retained; added; facts } ->
    Printf.sprintf
      "%s.%s: %d retained plus %d added does not equal %d %s"
      field_change
      field_retained
      retained
      added
      facts
      field_facts
;;

let snapshot_rejection_to_string = function
  | Snapshot_undecodable error -> Keeper_memory_os_types.wire_error_to_string error
  | Snapshot_inconsistent inconsistency ->
    snapshot_inconsistency_to_string inconsistency
;;

(* Each of the four consistency rules names the row it refused. Answering one
   bool for the whole snapshot meant a refused file on disk could only be read
   by re-deriving this function by hand. *)
let snapshot_change_rejection ~facts ~current_ids ~change =
  let current_by_id =
    List.fold_left
      (fun by_id fact -> Identity_map.add (memory_id fact) fact by_id)
      Identity_map.empty
      facts
  in
  let rec added_rejection = function
    | [] -> None
    | added :: rest ->
      (match Identity_map.find_opt (memory_id added) current_by_id with
       | Some current when String.equal (fact_payload added) (fact_payload current) ->
         added_rejection rest
       | Some _ | None -> Some (Added_row_is_not_current (memory_id added)))
  in
  let rec removed_rejection = function
    | [] -> None
    | removed :: rest ->
      (match Identity_map.find_opt (memory_id removed) current_by_id with
       | Some current when String.equal (fact_payload removed) (fact_payload current)
         -> Some (Removed_row_is_still_current (memory_id removed))
       | Some _ | None -> removed_rejection rest)
  in
  let rec invalidated_rejection = function
    | [] -> None
    | invalidation :: rest ->
      let identity = memory_id invalidation.fact in
      if Set_util.StringSet.mem identity current_ids
      then Some (Invalidated_row_is_current identity)
      else (
        match invalidation.fact.basis with
        | Observed _ -> Some (Invalidated_row_is_observed identity)
        | Derived derivations ->
          if derivations_supported current_ids derivations
          then Some (Invalidated_row_is_still_supported identity)
          else if
            not
              (List.equal
                 String.equal
                 invalidation.missing_premise_ids
                 (missing_premises_for current_ids derivations))
          then Some (Invalidated_premises_do_not_match identity)
          else invalidated_rejection rest)
  in
  let retained_rejection () =
    let added = List.length change.added in
    let facts = List.length facts in
    if change.retained + added = facts
    then None
    else Some (Retained_does_not_add_up { retained = change.retained; added; facts })
  in
  match added_rejection change.added with
  | Some _ as rejection -> rejection
  | None ->
    (match removed_rejection change.removed with
     | Some _ as rejection -> rejection
     | None ->
       (match invalidated_rejection change.invalidated with
        | Some _ as rejection -> rejection
        | None -> retained_rejection ()))
;;

let to_json snapshot =
  `Assoc
    [ field_revision, `Int snapshot.revision
    ; field_updated_at, `Float snapshot.updated_at
    ; field_source, source_to_json snapshot.source
    ; field_facts, facts_to_json snapshot.facts
    ; field_change, change_to_json snapshot.change
    ]
;;

let snapshot_bytes snapshot =
  Yojson.Safe.pretty_to_string (to_json snapshot) ^ "\n"
;;

let snapshot_sha256 snapshot = sha256 (snapshot_bytes snapshot)

let of_json json =
  let wire result = Result.map_error (fun error -> Snapshot_undecodable error) result in
  match json with
  | `Assoc fields ->
    let* () =
      wire
        (exact_field_names_result
           [ field_revision; field_updated_at; field_source; field_facts; field_change ]
           fields)
    in
    let* revision = wire (wire_int_field field_revision fields) in
    let* updated_at = wire (wire_number_field field_updated_at fields) in
    let* source_json = wire (wire_json_field field_source fields) in
    let* facts_json = wire (wire_json_field field_facts fields) in
    let* change_json = wire (wire_json_field field_change fields) in
    let* source =
      wire (wire_at (Wire_field field_source) (source_of_json source_json))
    in
    let* facts = wire (wire_at (Wire_field field_facts) (facts_of_json facts_json)) in
    let* change =
      wire (wire_at (Wire_field field_change) (change_of_json change_json))
    in
    let* () =
      wire
        (if revision >= 1
         then Ok ()
         else wire_fail [ Wire_field field_revision ] Not_positive)
    in
    let* () =
      wire
        (if Float.is_finite updated_at
         then Ok ()
         else wire_fail [ Wire_field field_updated_at ] Not_finite)
    in
    let* () =
      wire
        (if updated_at >= 0.0
         then Ok ()
         else wire_fail [ Wire_field field_updated_at ] Negative)
    in
    (* [facts_of_json] has already refused a repeated identity, so a closure
       smaller than the stored set can only mean a row lost its support. *)
    let current_ids = support_closure_ids facts in
    let* () =
      match
        List.filter
          (fun fact -> not (Set_util.StringSet.mem (memory_id fact) current_ids))
          facts
      with
      | [] -> Ok ()
      | _ :: _ as unsupported ->
        Error
          (Snapshot_inconsistent
             (Stored_rows_are_unsupported (List.map memory_id unsupported)))
    in
    (match snapshot_change_rejection ~facts ~current_ids ~change with
     | Some inconsistency -> Error (Snapshot_inconsistent inconsistency)
     | None -> Ok { revision; updated_at; source; facts; change })
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire (wire_here Expected_object)
;;

let parse path content =
  try
    Result.map_error
      (fun rejection ->
         Printf.sprintf
           "%s: current Memory OS snapshot rejected: %s"
           path
           (snapshot_rejection_to_string rejection))
      (of_json (Yojson.Safe.from_string content))
  with
  | Yojson.Json_error message ->
    Error (Printf.sprintf "%s: invalid JSON: %s" path message)
;;

let read_with_content ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    match Fs_compat.load_file_opt snapshot_path with
    | None -> Ok None
    | Some content ->
      let+ snapshot = parse snapshot_path content in
      Some (snapshot, content)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error message ->
    Error
      (Printf.sprintf
         "current Memory OS read failed path=%s: %s"
         snapshot_path
         message)
;;

let read_for_keepers_dir ~keepers_dir ~keeper_id =
  read_with_content ~keepers_dir ~keeper_id
  |> Result.map (Option.map fst)
;;

type read_classified =
  | No_snapshot
  | Readable of t
  | Undecodable of { rejection : string }
  | Io_unreadable of { detail : string }

let read_classified ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    match Fs_compat.load_file_opt snapshot_path with
    | None -> No_snapshot
    | Some content ->
      (match parse snapshot_path content with
       | Ok snapshot -> Readable snapshot
       | Error rejection -> Undecodable { rejection })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error message ->
    Io_unreadable
      { detail =
          Printf.sprintf
            "current Memory OS read failed path=%s: %s"
            snapshot_path
            message
      }
;;

let read_with_snapshot_sha256 ~keepers_dir ~keeper_id =
  read_with_content ~keepers_dir ~keeper_id
  |> Result.map
       (Option.map (fun (snapshot, content) -> snapshot, sha256 content))
;;

let librarian_failure_kind_to_string = function
  | Prompt_render_failure -> "prompt_render_failure"
  | Execution_clock_unavailable -> "execution_clock_unavailable"
  | Exact_setup_failure -> "exact_setup_failure"
  | Exact_execution_failure -> "exact_execution_failure"
  | Domain_output_invalid -> "domain_output_invalid"
  | Absorb_judgment_failure -> "absorb_judgment_failure"
  | Memory_snapshot_write_failure -> "memory_snapshot_write_failure"
  | Runtime_context_unavailable -> "runtime_context_unavailable"
  | Lane_cancelled -> "lane_cancelled"
  | Unhandled_exception -> "unhandled_exception"
;;

let librarian_failure_kind_of_string = function
  | "prompt_render_failure" -> Some Prompt_render_failure
  | "execution_clock_unavailable" -> Some Execution_clock_unavailable
  | "exact_setup_failure" -> Some Exact_setup_failure
  | "exact_execution_failure" -> Some Exact_execution_failure
  | "domain_output_invalid" -> Some Domain_output_invalid
  | "absorb_judgment_failure" -> Some Absorb_judgment_failure
  | "memory_snapshot_write_failure" -> Some Memory_snapshot_write_failure
  | "runtime_context_unavailable" -> Some Runtime_context_unavailable
  | "lane_cancelled" -> Some Lane_cancelled
  | "unhandled_exception" -> Some Unhandled_exception
  | _ -> None
;;

let committed_outcome = "committed"
let failed_outcome = "failed"
let quarantined_outcome = "quarantined"

(* [dropped_statements = None] means the writer makes no drop-reason
   statements (explicit keeper writes, upserts); [Some list] is the
   librarian's own account of the drops this commit carried out, possibly
   empty ([dropped_by_commit]). Statements live on the journal line and its
   pending removal receipt; the snapshot's [change.removed] preserves the
   originals until finalization. *)
let revision_links_to_json links = `List (List.map (fun (link : revision) ->
  `Assoc ["superseded", `String link.superseded; "superseded_by", `String link.superseded_by]) links)
;;

let revision_links_of_json = function
  | `List rows ->
    let rec decode seen = function
      | [] -> Ok []
      | `Assoc fields :: rest ->
        let* () = exact_field_names_result ["superseded"; "superseded_by"] fields
          |> Result.map_error wire_error_to_string in
        let* superseded = wire_string_field "superseded" fields |> Result.map_error wire_error_to_string in
        let* superseded_by = wire_string_field "superseded_by" fields |> Result.map_error wire_error_to_string in
        if not (is_memory_id superseded && is_memory_id superseded_by)
          || superseded = superseded_by || List.mem (superseded, superseded_by) seen
        then Error "invalid or duplicate revision link identity"
        else let+ rest = decode ((superseded, superseded_by) :: seen) rest in
          {superseded; superseded_by} :: rest
      | _ :: _ -> Error "revision link is not an object" in
    decode [] rows
  | _ -> Error "revision links are not an array"
;;

let journal_revision_links fields =
  match List.assoc_opt "revision_links" fields with
  | None -> Ok None
  | Some json -> Result.map Option.some (revision_links_of_json json)
;;

let links_applied_to_snapshot (snapshot : t) links =
  List.for_all (fun (link : revision) ->
    List.exists (fun fact -> memory_id fact = link.superseded) snapshot.change.removed
    && not (List.exists (fun fact -> memory_id fact = link.superseded) snapshot.facts)
    && List.exists (fun fact -> memory_id fact = link.superseded_by) snapshot.facts) links
;;

let journal_entry_to_json ~commit_effect ~revision_links ~dropped_statements snapshot =
  `Assoc
    ([ "outcome", `String committed_outcome
     ; "commit_effect", `String (match commit_effect with Rewritten -> "rewritten" | Unchanged -> "unchanged")
     ; "recorded_at", `Float snapshot.updated_at
     ; "revision", `Int snapshot.revision
     ; "source", source_to_json snapshot.source
     ; "change", change_to_json snapshot.change
     ]
     @ (match commit_effect with
        | Rewritten -> ["revision_links", revision_links_to_json revision_links]
        | Unchanged -> [])
     @
     match dropped_statements with
     | None -> []
     | Some statements ->
       [ ( "dropped"
         , `List (List.map dropped_statement_to_json statements) )
       ])
;;

let journal_failure_to_json ~now ~trace_id ~kind ~detail ~snapshot_present =
  `Assoc
    [ "outcome", `String failed_outcome
    ; "recorded_at", `Float now
    ; "trace_id", `String trace_id
    ; "kind", `String (librarian_failure_kind_to_string kind)
    ; "detail", `String detail
    ; "snapshot_present", `Bool snapshot_present
    ]
;;

let journal_commit_effect fields =
  match List.assoc_opt "commit_effect" fields with
  | None -> Ok None
  | Some (`String "rewritten") -> Ok (Some Rewritten)
  | Some (`String "unchanged") -> Ok (Some Unchanged)
  | Some _ -> Error "committed line has an invalid commit_effect"
;;

let committed_entry_of_fields fields =
  let* transition = journal_commit_effect fields in
  let* links = journal_revision_links fields in
  let* () = match links, transition with
    | Some (_ :: _), Some Rewritten -> Ok ()
    | Some (_ :: _), (Some Unchanged | None) -> Error "revision links lack a snapshot transition"
    | (Some [] | None), _ -> Ok () in
  let expected = ["outcome"; "recorded_at"; "revision"; "source"; "change"]
    @ (if List.mem_assoc "dropped" fields then ["dropped"] else [])
    @ (if List.mem_assoc "commit_effect" fields then ["commit_effect"] else [])
    @ (if List.mem_assoc "revision_links" fields then ["revision_links"] else []) in
  let fields_are_exact = exact_object_fields expected fields in
  let dropped_of_json = function
    | `List items ->
      let rec loop index acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest ->
          (match Keeper_memory_os_types.dropped_statement_of_json item with
           | Ok statement -> loop (index + 1) (statement :: acc) rest
           | Error error ->
             Error
               (Printf.sprintf
                  "[%d] %s"
                  index
                  (Keeper_memory_os_types.wire_error_to_string error)))
      in
      loop 0 [] items
    | _ -> Error "is not an array"
  in
  if not fields_are_exact
  then Error "committed line has unknown, duplicate, or missing fields"
  else
  match
    ( List.assoc_opt "recorded_at" fields
    , List.assoc_opt "revision" fields
    , List.assoc_opt "source" fields
    , List.assoc_opt "change" fields )
  with
  | Some (`Float recorded_at), Some (`Int revision), Some source, Some change ->
    (match source_of_json source, change_of_json change with
     | Error error, _ ->
       Error
         (Printf.sprintf
            "committed line has an undecodable source: %s"
            (Keeper_memory_os_types.wire_error_to_string error))
     | Ok _, Error error ->
       Error
         (Printf.sprintf
            "committed line has an undecodable change: %s"
            (Keeper_memory_os_types.wire_error_to_string error))
     | Ok _, Ok _ when revision < 0 -> Error "committed line has a negative revision"
     | Ok source, Ok change ->
       (match List.assoc_opt "dropped" fields with
        | None ->
          Ok (Journal_committed { recorded_at; revision; source; change; dropped = None })
        | Some dropped ->
          (match dropped_of_json dropped with
           | Ok statements ->
             Ok
               (Journal_committed
                  { recorded_at; revision; source; change; dropped = Some statements })
           | Error detail ->
             Error
               (Printf.sprintf
                  "committed line has an undecodable dropped list: %s"
                  detail))))
  | _ -> Error "committed line is missing recorded_at/revision/source/change"
;;

let failed_entry_of_fields fields =
  if
    not
      (exact_object_fields
         [ "outcome"
         ; "recorded_at"
         ; "trace_id"
         ; "kind"
         ; "detail"
         ; "snapshot_present"
         ]
         fields)
  then Error "failed line has unknown, duplicate, or missing fields"
  else
  match
    ( List.assoc_opt "recorded_at" fields
    , List.assoc_opt "trace_id" fields
    , List.assoc_opt "kind" fields
    , List.assoc_opt "detail" fields
    , List.assoc_opt "snapshot_present" fields )
  with
  | ( Some (`Float recorded_at)
    , Some (`String trace_id)
    , Some (`String kind)
    , Some (`String detail)
    , Some (`Bool snapshot_present) ) ->
    (match librarian_failure_kind_of_string kind with
     | Some kind ->
       Ok (Journal_failed { recorded_at; trace_id; kind; detail; snapshot_present })
     | None -> Error (Printf.sprintf "failed line has an unknown kind %S" kind))
  | _ ->
    Error "failed line is missing recorded_at/trace_id/kind/detail/snapshot_present"
;;

let quarantined_entry_of_fields fields =
  if
    not
      (exact_object_fields
         [ "outcome"; "recorded_at"; "rejection"; "rejected_path" ]
         fields)
  then Error "quarantined line has unknown, duplicate, or missing fields"
  else
    match
      ( List.assoc_opt "recorded_at" fields
      , List.assoc_opt "rejection" fields
      , List.assoc_opt "rejected_path" fields )
    with
    | ( Some (`Float recorded_at)
      , Some (`String rejection)
      , Some (`String rejected_path) ) ->
      Ok (Journal_quarantined { recorded_at; rejection; rejected_path })
    | _ ->
      Error "quarantined line is missing recorded_at/rejection/rejected_path"
;;

let journal_entry_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "outcome" fields with
     | Some (`String outcome) when String.equal outcome committed_outcome ->
       committed_entry_of_fields fields
     | Some (`String outcome) when String.equal outcome failed_outcome ->
       failed_entry_of_fields fields
     | Some (`String outcome) when String.equal outcome quarantined_outcome ->
       quarantined_entry_of_fields fields
     | Some (`String outcome) ->
       Error (Printf.sprintf "journal line has an unknown outcome %S" outcome)
     | Some _ -> Error "journal line has a non-string outcome"
     | None -> Error "journal line has no outcome tag")
  | _ -> Error "journal line is not a JSON object"
;;

module Recall_revision_set = Set.Make (Int)

type recall_journal_projection =
  { revisions : Recall_revision_set.t
  ; retired : int Identity_map.t
  ; highest : int
  ; rewrites_rev : Yojson.Safe.t list
  ; invalid : string option
  }

type recall_journal_cache =
  { oldest : int
  ; identity : Unix.stats
  ; projection : recall_journal_projection
  }

let recall_journal_cache = Atomic.make Identity_map.empty
let empty_recall_projection =
  {revisions=Recall_revision_set.empty;retired=Identity_map.empty;highest=0;rewrites_rev=[];invalid=None}

let rec publish_recall_cache path value =
  let before = Atomic.get recall_journal_cache in
  let after = match value with
    | None -> Identity_map.remove path before
    | Some entry -> Identity_map.add path entry before in
  if not (Atomic.compare_and_set recall_journal_cache before after) then
    publish_recall_cache path value

(* Only a line that rewrote the snapshot covers its revision. An unchanged
   observation repeats a revision another line wrote, and a line without a
   commit effect proves neither. *)
let journal_line_rewrote (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match journal_commit_effect fields with
     | Ok (Some Rewritten) -> true
     | Ok (Some Unchanged | None) | Error _ -> false)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false

(* Forward projection matches the previous reverse reader's stopping boundary.
   Only snapshot rewrites cover revisions; unchanged observations never fill a
   missing transition. No observation rows are retained in memory. *)
let project_recall_entry ~oldest projection = function
  | Dated_jsonl.Malformed_json {detail;_} -> {projection with invalid=Some detail}
  | Dated_jsonl.Parsed json ->
    match journal_entry_of_json json with
    | Error detail -> {projection with invalid=Some detail}
    | Ok (Journal_failed _ | Journal_quarantined _) -> projection
    | Ok (Journal_committed {revision;change;_}) ->
      if revision <= oldest then empty_recall_projection
      else
        let rewrote = journal_line_rewrote json in
        let revisions =
          if rewrote then Recall_revision_set.add revision projection.revisions
          else projection.revisions in
        let rewrites_rev =
          if rewrote then json :: projection.rewrites_rev else projection.rewrites_rev in
        let added = Set_util.StringSet.of_list (List.map memory_id change.added) in
        let retired = List.fold_left (fun retired fact ->
          let id = memory_id fact in
          if Set_util.StringSet.mem id added then retired
          else Identity_map.update id
            (function None -> Some revision | Some prior -> Some (max prior revision)) retired)
          projection.retired change.removed in
        {projection with revisions;retired;rewrites_rev;highest=max projection.highest revision}

let observe_recall_append path (observation : Fs_compat.private_jsonl_append_observation) json =
  match Identity_map.find_opt path (Atomic.get recall_journal_cache) with
  | None -> ()
  | Some cached ->
    let before=observation.before and after=observation.after in
    if same_file_identity cached.identity before
       && before.Unix.st_dev=after.Unix.st_dev && before.Unix.st_ino=after.Unix.st_ino
       && after.Unix.st_size-before.Unix.st_size=String.length observation.suffix
       && String.equal observation.suffix (Yojson.Safe.to_string json ^ "\n")
    then publish_recall_cache path (Some {cached with identity=after;
      projection=project_recall_entry ~oldest:cached.oldest cached.projection
        (Dated_jsonl.Parsed json)})
    else publish_recall_cache path None

(* Every journal writer and receipt recovery uses the canonical path mutex
   and stable sibling lock. A data-file lock can be released by an unrelated
   reader closing the journal; the sibling lock remains held through append. *)
let append_journal_line_strict ~keepers_dir ~keeper_id json =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let suffix = Yojson.Safe.to_string json ^ "\n" in
  match Fs_compat.append_private_jsonl_durable_observed_result path suffix with
  | Ok (_, observation) ->
    (match observation with
     | None -> publish_recall_cache path None
     | Some observation -> observe_recall_append path observation json);
    Ok ()
  | Error error ->
    Error
      (Printf.sprintf
         "memory journal durable append failed path=%s: %s"
         path
         (Fs_compat.private_jsonl_transaction_error_to_string error))
;;

(* Lines without actual reason-bearing removals are observations: their
   snapshot already reached disk, so append failure warns. Destructive
   removals below use [append_journal_line_strict] and a prepared receipt so
   their originals and reasons survive failed journal finalization.
   Cancellation is never absorbed. *)
let append_journal_line ~keepers_dir ~keeper_id json =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    match append_journal_line_strict ~keepers_dir ~keeper_id json with
    | Ok () -> ()
    | Error detail -> Log.Keeper.warn "%s" detail
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn ->
    Log.Keeper.warn
      "memory journal append failed path=%s: %s"
      path
      (Printexc.to_string exn)
;;

let append_journal_entry ~keepers_dir ~keeper_id ~commit_effect ~revision_links ~dropped_statements snapshot =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (journal_entry_to_json ~commit_effect ~revision_links ~dropped_statements snapshot)
;;

(* A committed line's [dropped] lists what this commit removed: a memory the
   locked snapshot held and the next one does not. An answer can drop a memory
   the commit keeps -- its only successor was not stored -- or one the keeper
   already removed during the pass. Written as given, the append-only journal
   would say a current memory was dropped. *)
let dropped_by_commit ~(previous : t option) ~(next : t) statements =
  let ids facts =
    List.fold_left
      (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
      Set_util.StringSet.empty
      facts
  in
  let held_before =
    match previous with
    | None -> Set_util.StringSet.empty
    | Some snapshot -> ids snapshot.facts
  in
  let held_after = ids next.facts in
  List.filter
    (fun (statement : Keeper_memory_os_types.dropped_statement) ->
       Set_util.StringSet.mem statement.memory_id held_before
       && not (Set_util.StringSet.mem statement.memory_id held_after))
    statements
;;

let append_librarian_failure
      ~keepers_dir
      ~keeper_id
      ~now
      ~trace_id
      ~kind
      ~detail
      ~snapshot_present
  =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (journal_failure_to_json ~now ~trace_id ~kind ~detail ~snapshot_present)
;;

(* A snapshot this build cannot decode is durable state no producer can leave:
   every writer reads before it writes, so one undecodable file wedges the
   keeper's memory permanently. The bytes move aside rather than being deleted
   and this line says why, so a build that can read them again still has both.
   Recorded on its own outcome because it is neither a pass that committed nor
   a pass that failed. *)
let journal_quarantine_to_json ~now ~rejection ~rejected_path =
  `Assoc
    [ "outcome", `String quarantined_outcome
    ; "recorded_at", `Float now
    ; "rejection", `String rejection
    ; "rejected_path", `String rejected_path
    ]
;;

(* [now] is the caller's own observation time and repeats: two writes in the
   same second share it, and a caller may pass a fixed value. [rename] replaces
   its destination, so a repeated name would delete the snapshot an earlier
   quarantine kept — the one thing this path promises not to do. The search
   runs under the snapshot lock the writer already holds, so the name it
   settles on is still free when the rename happens. *)
let unused_rejected_path ~snapshot_path ~now =
  let base = Printf.sprintf "%s.rejected-%.0f" snapshot_path now in
  if not (Fs_compat.file_exists base)
  then base
  else (
    let rec next attempt =
      let candidate = Printf.sprintf "%s-%d" base attempt in
      if Fs_compat.file_exists candidate then next (attempt + 1) else candidate
    in
    next 2)
;;

let append_snapshot_quarantine ~keepers_dir ~keeper_id ~now ~rejection ~rejected_path =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (journal_quarantine_to_json ~now ~rejection ~rejected_path)
;;

type retraction_plan_receipt =
  { plan_id : string option
      (* [Some id] belongs to the exact batch API. [None] preserves an
         ordinary removal without claiming an operator-approved plan. *)
  ; prior_revision : int
  ; prior_snapshot_sha256 : string
  ; target_revision : int
  ; target_snapshot_sha256 : string
  ; dropped_statements : Keeper_memory_os_types.dropped_statement list
  ; revision_links : revision list
  }

let retraction_plan_receipt_to_json receipt =
  `Assoc
    [ "state", `String "prepared"
    ; "plan_id", (match receipt.plan_id with None -> `Null | Some id -> `String id)
    ; "prior_revision", `Int receipt.prior_revision
    ; "prior_snapshot_sha256", `String receipt.prior_snapshot_sha256
    ; "target_revision", `Int receipt.target_revision
    ; "target_snapshot_sha256", `String receipt.target_snapshot_sha256
    ; "revision_links", revision_links_to_json receipt.revision_links
    ; ( "dropped"
      , `List
          (List.map
             dropped_statement_to_json
             receipt.dropped_statements) )
    ]
;;

let retraction_plan_receipt_of_json = function
  | `Assoc fields
    when exact_object_fields
           [ "plan_id"
           ; "state"
           ; "prior_revision"
           ; "prior_snapshot_sha256"
           ; "target_revision"
           ; "target_snapshot_sha256"
           ; "revision_links"
           ; "dropped"
           ]
           fields
         (* Receipts prepared before [revision_links] existed carry the
            older seven-field shape. Read them with no lineage rather than
            refusing, so a leftover prepared receipt cannot block the next
            writer's recovery; the lineage is left empty instead of guessed,
            because an inferred link would fabricate history the old writer
            never recorded. *)
         || exact_object_fields
              [ "plan_id"
              ; "state"
              ; "prior_revision"
              ; "prior_snapshot_sha256"
              ; "target_revision"
              ; "target_snapshot_sha256"
              ; "dropped"
              ]
              fields ->
    (match
       ( List.assoc_opt "plan_id" fields
       , List.assoc_opt "state" fields
       , List.assoc_opt "prior_revision" fields
       , List.assoc_opt "prior_snapshot_sha256" fields
       , List.assoc_opt "target_revision" fields
       , List.assoc_opt "target_snapshot_sha256" fields
       , List.assoc_opt "dropped" fields )
     with
     | ( Some plan_id_json
       , Some (`String "prepared")
       , Some (`Int prior_revision)
       , Some (`String prior_snapshot_sha256)
       , Some (`Int target_revision)
       , Some (`String target_snapshot_sha256)
       , Some (`List dropped_json) )
       when prior_revision > 0
            && target_revision = prior_revision + 1
            && String_util.is_lowercase_sha256_hex prior_snapshot_sha256
            && String_util.is_lowercase_sha256_hex target_snapshot_sha256 ->
       let* revision_links = match List.assoc_opt "revision_links" fields with
         | Some json -> revision_links_of_json json
         | None -> Ok [] in
       let* plan_id =
         match plan_id_json with
         | `Null -> Ok None
         | `String plan_id
           when String.trim plan_id <> ""
                && String.equal plan_id (String.trim plan_id) -> Ok (Some plan_id)
         | _ -> Error "retraction plan identity is invalid"
       in
       let rec decode_dropped index seen acc = function
         | [] -> Ok (List.rev acc)
         | json :: rest ->
           (match Keeper_memory_os_types.dropped_statement_of_json json with
            | Ok statement
              when not
                     (Set_util.StringSet.mem statement.memory_id seen) ->
              decode_dropped
                (index + 1)
                (Set_util.StringSet.add statement.memory_id seen)
                (statement :: acc)
                rest
            | Ok statement ->
              Error
                (Printf.sprintf
                   "retraction plan dropped repeats memory_id %s"
                   statement.memory_id)
            | Error error ->
              Error
                (Printf.sprintf
                   "retraction plan dropped[%d] is invalid: %s"
                   index
                   (Keeper_memory_os_types.wire_error_to_string error)))
       in
       (match decode_dropped 0 Set_util.StringSet.empty [] dropped_json with
        | Ok dropped_statements when dropped_statements <> [] || revision_links <> [] ->
          Ok
            { plan_id
            ; prior_revision
            ; prior_snapshot_sha256
            ; target_revision
            ; target_snapshot_sha256
            ; dropped_statements
            ; revision_links
            }
        | Ok _ -> Error "prepared removal has neither reasons nor revision links"
        | Error _ as error -> error)
     | _ -> Error "retraction plan receipt fields are invalid")
  | _ ->
    Error "retraction plan receipt has unknown, duplicate, or missing fields"
;;

let read_retraction_plan_receipt ~keepers_dir ~keeper_id =
  let path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some content ->
    (match Yojson.Safe.from_string content with
     | json -> Result.map Option.some (retraction_plan_receipt_of_json json)
     | exception Yojson.Json_error detail ->
       Error
         (Printf.sprintf
            "retraction plan receipt is not JSON path=%s: %s"
            path
            detail))
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error
      (Printf.sprintf
         "retraction plan receipt unreadable path=%s: %s"
         path
         (Printexc.to_string exn))
;;

let write_retraction_plan_receipt ~keepers_dir ~keeper_id receipt =
  let path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  let json = retraction_plan_receipt_to_json receipt in
  let* _ = retraction_plan_receipt_of_json json in
  Fs_compat.save_file_atomic_strict path
    (Yojson.Safe.to_string json)
  |> Result.map_error (fun detail ->
       Printf.sprintf
         "retraction plan receipt write failed path=%s: %s"
         path
         detail)
;;

let remove_retraction_plan_receipt ~keepers_dir ~keeper_id =
  let path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  match Sys.remove path with
  | () -> Ok ()
  | exception Sys_error _ when not (Sys.file_exists path) -> Ok ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error
      (Printf.sprintf
         "retraction plan receipt removal failed path=%s: %s"
         path
         (Printexc.to_string exn))
;;

let append_removal_journal_and_clear_receipt
      ~keepers_dir ~keeper_id ~snapshot receipt
  =
  let* () = if links_applied_to_snapshot snapshot receipt.revision_links then Ok ()
    else Error "prepared revision links do not match the committed snapshot" in
  let* () =
    append_journal_line_strict
      ~keepers_dir
      ~keeper_id
      (journal_entry_to_json
         ~commit_effect:Rewritten
         ~revision_links:receipt.revision_links
         ~dropped_statements:(Some receipt.dropped_statements)
         snapshot)
  in
  remove_retraction_plan_receipt ~keepers_dir ~keeper_id
;;

(* Whether a committed line equal to a receipt's entry is that receipt's
   rewrite. A writer before [revision_links] recorded no links, and one before
   [commit_effect] recorded neither key; their receipts decode with no links.
   Reading such a line as absent would append the same revision twice. *)
let journal_line_records_rewrite fields ~revision_links =
  match journal_commit_effect fields, journal_revision_links fields with
  | Ok (Some Rewritten | None), Ok (Some links) -> links = revision_links
  | Ok (Some Rewritten | None), Ok None -> revision_links = []
  | Ok (Some Unchanged), _ | Error _, _ | Ok _, Error _ -> false
;;

let journal_contains_entry ~keepers_dir ~keeper_id ~revision_links expected =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  (* Only receipt reconciliation calls this, after proving the exact committed
     snapshot. A process interrupted during its append may leave a partial
     final row: recover that tail before deciding whether to append the
     preserved removal. General archive reads never perform this repair. *)
  match Fs_compat.recover_private_jsonl_durable_locked_result path with
  | Ok snapshot ->
    let content = snapshot.Fs_compat.bytes in
    let rec scan line_number = function
      | [] -> Ok false
      | line :: rest when String.equal (String.trim line) "" ->
        scan (line_number + 1) rest
      | line :: rest ->
        (match Yojson.Safe.from_string line with
         | json ->
           (match journal_entry_of_json json with
            | Ok observed when observed = expected ->
              (match json with
               | `Assoc fields when journal_line_records_rewrite fields ~revision_links -> Ok true
               | _ -> scan (line_number + 1) rest)
            | Ok _ -> scan (line_number + 1) rest
            | Error detail ->
              Error
                (Printf.sprintf
                   "memory journal line %d is undecodable during retraction reconciliation path=%s: %s"
                   line_number
                   path
                   detail))
         | exception Yojson.Json_error detail ->
           Error
             (Printf.sprintf
                "memory journal line %d is not JSON during retraction reconciliation path=%s: %s"
                line_number
                path
                detail))
    in
    scan 1 (String.split_on_char '\n' content)
  | Error error ->
    Error
      (Printf.sprintf
         "memory journal unreadable during retraction reconciliation path=%s: %s"
         path
         (Fs_compat.private_jsonl_transaction_error_to_string error))
;;

let reconcile_retraction_plan_receipt ~keepers_dir ~keeper_id ~snapshot =
  let* receipt = read_retraction_plan_receipt ~keepers_dir ~keeper_id in
  match receipt with
  | None -> Ok ()
  | Some receipt ->
    (match snapshot with
     | Some (current, content)
       when current.revision = receipt.prior_revision
            && String.equal (sha256 content) receipt.prior_snapshot_sha256 ->
      (* Preparation reached disk but replacement did not. Nothing was
         retracted, so the plan can be removed without journal evidence. *)
      remove_retraction_plan_receipt ~keepers_dir ~keeper_id
     | Some (current, content)
       when current.revision = receipt.target_revision
            && String.equal (sha256 content) receipt.target_snapshot_sha256 ->
      let* () =
        match receipt.plan_id, current.source with
        | None, _ -> Ok ()
        | Some plan_id, { kind = Explicit_retract; trace_id }
          when String.equal trace_id plan_id -> Ok ()
        | _ ->
          Error
            (Printf.sprintf
               "retraction plan target snapshot has another source target_revision=%d"
               receipt.target_revision)
      in
      let journal_entry =
        Journal_committed
          { recorded_at = current.updated_at
          ; revision = current.revision
          ; source = current.source
          ; change = current.change
          ; dropped = Some receipt.dropped_statements
          }
      in
      let* present =
        journal_contains_entry
          ~keepers_dir
          ~keeper_id
          ~revision_links:receipt.revision_links
          journal_entry
      in
      if present
      then remove_retraction_plan_receipt ~keepers_dir ~keeper_id
      else
        append_removal_journal_and_clear_receipt
          ~keepers_dir ~keeper_id ~snapshot:current receipt
     | None | Some _ ->
      Error
        (Printf.sprintf
           "retraction plan receipt conflicts with current snapshot prior_revision=%d target_revision=%d"
           receipt.prior_revision
           receipt.target_revision))
;;

(* The journal only grows (10-13 MB on live keepers) and a reader asks for its
   last 20-500 lines. Reading the whole file and splitting every line on each
   dashboard or TUI request put that copy and split on the scheduler domain;
   the tail is read backwards and only the returned lines are parsed, both in
   one pool job. Each line is named by the byte offset it starts at, which
   does not depend on the window it was read in. *)
let read_journal_tail_indexed ~keepers_dir ~keeper_id ~limit =
  if limit <= 0
  then []
  else (
    let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
    Dated_jsonl.map_tail_rows path ~max_lines:limit ~f:(fun { Dated_jsonl.offset; line } ->
      match Yojson.Safe.from_string line with
      | json -> offset, journal_entry_of_json json
      | exception Yojson.Json_error message ->
        offset, Error (Printf.sprintf "journal line is not valid JSON: %s" message)))
;;

let read_journal_tail ~keepers_dir ~keeper_id ~limit =
  read_journal_tail_indexed ~keepers_dir ~keeper_id ~limit |> List.map snd
;;

type removal_lookup =
  | Removed of removal
  | No_removal_recorded
  | Journal_unreadable of string

type journal_mention =
  | Mentioned_as_current
  | Mentioned_as_removed of removal
  | Mention_unreadable of string

(* Newest line first: the latest committed line that names the identity
   decides. A line that adds it (a re-observation lists it on both sides)
   leaves it current after that line, so no removal is reported. An unreadable
   newer line stops the search: it may replace the authority an older removal
   would otherwise grant. An identity no line names is scanned to the start
   of the file, decoding every line, so the scan runs as one pool job, as the
   tail reader above does. *)
let find_removal ~keepers_dir ~keeper_id target =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let is_target fact = String.equal (Keeper_memory_os_types.memory_id fact) target in
  let reason_for dropped =
    Option.bind dropped (fun statements ->
      List.find_map
        (fun (statement : Keeper_memory_os_types.dropped_statement) ->
           if String.equal statement.memory_id target then Some statement.reason else None)
        statements)
  in
  let mention = function
    | Dated_jsonl.Malformed_json { path; detail; line_number = _ } ->
      Some (Mention_unreadable (Printf.sprintf "memory journal %s: %s" path detail))
    | Dated_jsonl.Parsed json ->
      (match journal_entry_of_json json with
       | Ok (Journal_committed { recorded_at; revision; source; change; dropped }) ->
         if List.exists is_target change.added
         then Some Mentioned_as_current
         else (
           match List.find_opt is_target change.removed with
           | Some (removed : Keeper_memory_os_types.fact) ->
             Some
               (Mentioned_as_removed
                  { removed_in_revision = revision
                  ; removed_at = recorded_at
                  ; removed_by = source
                  ; removed_origin = removed.origin.kind
                  ; drop_reason = reason_for dropped
                  })
           | None -> None)
       | Ok (Journal_failed _ | Journal_quarantined _) -> None
       | Error detail ->
         Some (Mention_unreadable (Printf.sprintf "memory journal %s: %s" path detail)))
  in
  if not (Sys.file_exists path)
  then No_removal_recorded
  else (
    match
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Dated_jsonl.find_latest_entry_in_file_result path mention)
    with
    | Ok (Some (Mentioned_as_removed removal)) -> Removed removal
    | Ok (Some Mentioned_as_current | None) -> No_removal_recorded
    | Ok (Some (Mention_unreadable detail)) -> Journal_unreadable detail
    | Error error -> Journal_unreadable (Dated_jsonl.read_error_to_string error))
;;

type archived_fact =
  { original : Keeper_memory_os_types.fact
  ; removal : removal
  }

let read_dropped ~keepers_dir ~keeper_id ~current_facts =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  Domain_pool_ref.submit_io_or_inline (fun () ->
    let* receipt = read_retraction_plan_receipt ~keepers_dir ~keeper_id in
    let* () =
      match receipt with
      | None -> Ok ()
      | Some receipt ->
        Error
          (Printf.sprintf
             "memory archive journal finalization pending keeper=%s target_revision=%d; a writer must reconcile the preserved removal before the archive can be read"
             keeper_id
             receipt.target_revision)
    in
    let seen = ref (Set_util.StringSet.of_list (List.map memory_id current_facts)) in
    let archived = ref [] in
    let visit = function
      | Dated_jsonl.Malformed_json { detail; _ } -> Some detail
      | Dated_jsonl.Parsed json ->
        match journal_entry_of_json json with
        | Error detail -> Some detail
        | Ok (Journal_failed _ | Journal_quarantined _) -> None
        | Ok (Journal_committed { recorded_at; revision; source; change; dropped }) ->
          (* Additions in the same commit win, matching find_removal. Latest
             mentions suppress older removals even when their reason is absent. *)
          List.iter (fun fact -> seen := Set_util.StringSet.add (memory_id fact) !seen)
            change.added;
          List.iter
            (fun fact ->
               let identity = memory_id fact in
               if not (Set_util.StringSet.mem identity !seen) then (
                 seen := Set_util.StringSet.add identity !seen;
                 let reason = Option.bind dropped (List.find_map
                   (fun (statement : dropped_statement) ->
                      if String.equal statement.memory_id identity
                      then Some statement.reason else None)) in
                 match reason with
                 | None -> ()
                 | Some reason ->
                   archived :=
                     { original = fact
                     ; removal =
                         { removed_in_revision = revision
                         ; removed_at = recorded_at
                         ; removed_by = source
                         ; removed_origin = fact.origin.kind
                         ; drop_reason = Some reason
                         }
                     } :: !archived))
            change.removed;
          None
    in
    match Unix.lstat path with
    | _ ->
      (match Dated_jsonl.find_latest_entry_in_file_result path visit with
       | Ok None -> Ok (List.rev !archived)
       | Ok (Some detail) -> Error detail
       | Error error -> Error (Dated_jsonl.read_error_to_string error))
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
    | exception Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
;;

type retirement_context =
  | Retirement_source_changed
  | Retirement_source_unavailable of string
  | Retirement_archive of (archived_fact list, string) result

let read_retirement_context ~keepers_dir ~keeper_id ~expected_revision ~current_facts =
  try
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
      File_lock_eio.with_lock path (fun () ->
        match read_classified ~keepers_dir ~keeper_id with
        | Readable snapshot when Some snapshot.revision = expected_revision
            && snapshot.facts = current_facts ->
            Retirement_archive (read_dropped ~keepers_dir ~keeper_id ~current_facts)
        | No_snapshot when expected_revision = None && current_facts = [] ->
            Retirement_archive (read_dropped ~keepers_dir ~keeper_id ~current_facts)
        | Undecodable {rejection} when expected_revision = None && current_facts = [] ->
            Retirement_archive (Error rejection)
        | Readable _ | No_snapshot | Undecodable _ -> Retirement_source_changed
        | Io_unreadable {detail} -> Retirement_source_unavailable detail))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Retirement_source_unavailable (Printexc.to_string exn)
;;

(* The targets some committed line newer than [revision] removed without
   adding back in the same line. Read newest first and stopped at the first
   line at or below [revision], so it costs the commits since the decision,
   not the journal's length. [None] reads every line: the decision saw no
   snapshot. [held] is the revision of the snapshot the caller holds locked.
   Once Memory moved after the decision, an empty set is a proof only if the
   journal holds a rewriting line for every revision in between: a commit
   without drop reasons appends its line best-effort, so a lost line can hide
   a removal that a later line adds back. Revisions restart after a
   quarantine, so a quarantine in that window ends the proof too. Caller holds
   the aggregate and snapshot locks, as for [read_dropped]. *)
let targets_retired_since ~keepers_dir ~keeper_id ~revision ~held targets =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  (* Snapshot revisions start at 1, so 0 stands for no snapshot. *)
  let decided = Option.value revision ~default:0 in
  let held = Option.value held ~default:0 in
  let moved = held > decided in
  let retired = ref Set_util.StringSet.empty in
  let rewritten = ref Recall_revision_set.empty in
  let newer line_revision = match revision with
    | None -> true
    | Some decided -> line_revision > decided in
  let visit = function
    | Dated_jsonl.Malformed_json { detail; _ } -> Some (Error detail)
    | Dated_jsonl.Parsed json ->
      match journal_entry_of_json json with
      | Error detail -> Some (Error detail)
      | Ok (Journal_failed _) -> None
      | Ok (Journal_quarantined _) ->
        if moved
        then Some (Error "a quarantine restarted Memory revisions after the admission decision")
        else None
      | Ok (Journal_committed { revision = line_revision; change; _ }) ->
        if not (newer line_revision) then Some (Ok ())
        else if moved && line_revision > held then
          Some (Error (Printf.sprintf
            "journal revision %d is ahead of the locked snapshot revision %d"
            line_revision held))
        else (
          if line_revision > decided && journal_line_rewrote json then
            rewritten := Recall_revision_set.add line_revision !rewritten;
          let added = Set_util.StringSet.of_list (List.map memory_id change.added) in
          List.iter (fun fact ->
            let identity = memory_id fact in
            if Set_util.StringSet.mem identity targets
               && not (Set_util.StringSet.mem identity added)
            then retired := Set_util.StringSet.add identity !retired) change.removed;
          None) in
  (* Lines above [held] were refused and the scan stopped at the decision, so
     the count proves each revision in between. *)
  let proven () =
    if (not moved) || Recall_revision_set.cardinal !rewritten = held - decided
    then Ok !retired
    else
      Error (Printf.sprintf
        "journal lacks a Memory revision between the admission decision %d and the locked snapshot %d"
        decided held) in
  if held < decided then
    Error (Printf.sprintf
      "the locked snapshot revision %d is behind the admission decision %d" held decided)
  else
    match Unix.lstat path with
    | _ ->
      (match Dated_jsonl.find_latest_entry_in_file_result path visit with
       | Ok (None | Some (Ok ())) -> proven ()
       | Ok (Some (Error detail)) -> Error detail
       | Error error -> Error (Dated_jsonl.read_error_to_string error))
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> proven ()
    | exception Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
;;

(* An exact retraction batch: its plan id and the error that reports pending
   journal evidence for the snapshot it wrote. *)
type 'error retraction_plan =
  string
  * (plan_id:string -> snapshot_revision:int -> snapshot_sha256:string -> detail:string -> 'error)

(* What a commit does when its facts equal the stored ones. A Librarian pass
   keeps the stored snapshot. An explicit write still writes a revision: its
   caller reads the returned [change] as what that write did, and the keeper
   stamps [last_seen] with the write time, so an equal set does not arise
   from it in practice. A retraction plan is an explicit write, so a kept
   pass never carries one. *)
type 'error equal_facts =
  | Keep_stored
  | Write_revision of 'error retraction_plan option

(* Caller holds the aggregate and snapshot locks. Both boot and ordinary
   writers must move the removal receipt with an undecodable snapshot. *)
let quarantine_snapshot_and_receipt ~keepers_dir ~keeper_id ~snapshot_path ~now ~rejection =
  let move path =
    let rejected_path = unused_rejected_path ~snapshot_path:path ~now in
    match Fs_compat.rename_noreplace path rejected_path with
    | () -> Ok rejected_path
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      Error
        (Printf.sprintf
           "current Memory OS file could not be moved aside path=%s rejected_path=%s: %s (rejected: %s)"
           path
           rejected_path
           (Printexc.to_string exn)
           rejection)
  in
  (* A receipt and its target snapshot carry one pending removal. Move
     the receipt first: interruption then leaves the rejected snapshot
     to refuse boot again, instead of an active receipt whose snapshot
     has disappeared. Preserve raw bytes; a rejected snapshot cannot
     prove either receipt hash, so it cannot authorize reconciliation. *)
  let receipt_path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  let* moved_receipt =
    match Fs_compat.exact_path_kind ~follow:false receipt_path with
    | Fs_compat.Exact_missing -> Ok None
    | Fs_compat.Exact_kind _ ->
      let+ rejected_receipt_path = move receipt_path in
      Log.Keeper.warn
        ~keeper_name:keeper_id
        "memory removal receipt quarantined path=%s rejected_path=%s"
        receipt_path
        rejected_receipt_path;
      Some rejected_receipt_path
    | Fs_compat.Exact_unknown ->
      Error
        (Printf.sprintf
           "current Memory OS removal receipt could not be inspected path=%s; snapshot was not moved"
           receipt_path)
  in
  match move snapshot_path with
  | Ok rejected_path ->
    append_snapshot_quarantine ~keepers_dir ~keeper_id ~now ~rejection ~rejected_path;
    Ok rejected_path
  | Error detail ->
    Error
      (match moved_receipt with
       | None -> detail
       | Some rejected_receipt_path ->
         Printf.sprintf
           "%s; removal receipt is preserved at %s and the rejected snapshot stays in place"
           detail
           rejected_receipt_path)
;;

let update_locked_with_output
      ?on_committed
      ?clock
      ?dropped_statements
      ?before_replace
      ?(declared_revisions = [])
      ?durable_range_id
      ?official_range_id
      ?(explicit_candidate_ids = [])
      ?admission_recall
      ~equal_facts
      ~store_error
      ~keepers_dir
      ~keeper_id
      ~now
      build
  =
  let retraction_plan =
    match equal_facts with
    | Keep_stored -> None
    | Write_revision plan -> plan
  in
  let admission_recall_bindings = match admission_recall with
    | None -> []
    | Some recall -> recall.bindings in
  let* () =
    match official_range_id with
    | None -> Ok ()
    | Some range ->
      official_range_id_of_json (official_range_id_to_json range)
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun error -> store_error (wire_error_to_string error))
  in
  let* () = List.fold_left (fun result candidate ->
    let* () = result in
    explicit_candidate_id_of_json (explicit_candidate_id_to_json candidate)
    |> Result.map ignore
    |> Result.map_error (fun error -> store_error (wire_error_to_string error)))
    (Ok ()) explicit_candidate_ids in
  let* () = List.fold_left (fun result binding ->
    let* () = result in
    admission_recall_binding_of_json (admission_recall_binding_to_json binding)
    |> Result.map ignore
    |> Result.map_error (fun error -> store_error (wire_error_to_string error)))
    (Ok ()) admission_recall_bindings in
  let* () = validate_unique_explicit_candidates
    (List.map (fun binding -> binding.candidate_id) admission_recall_bindings)
    |> Result.map_error store_error in
  let* () = revision_links_of_json (revision_links_to_json declared_revisions)
    |> Result.map ignore |> Result.map_error store_error in
  let dropped_statements_are_valid =
    match dropped_statements with
    | None -> true
    | Some statements ->
      List.for_all
        (fun (statement : Keeper_memory_os_types.dropped_statement) ->
           Keeper_memory_os_types.is_memory_id statement.memory_id
           && not (String.equal (String.trim statement.reason) ""))
        statements
  in
  let retraction_plan_is_valid =
    match retraction_plan with
    | None -> true
    | Some (plan_id, _) ->
      String.trim plan_id <> "" && String.equal plan_id (String.trim plan_id)
  in
  if not dropped_statements_are_valid
  then Error (store_error "dropped statements must carry canonical identities and reasons")
  else if not retraction_plan_is_valid
  then Error (store_error "retraction plan id must be non-empty and already trimmed")
  else (
    Fs_compat.mkdir_p keepers_dir;
    let notification_keepers_dir = Unix.realpath keepers_dir in
    let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let committed = ref None in
    let notify () =
      Option.iter Keeper_memory_commit_notifications.notify_committed !committed
    in
    let write () = Keeper_memory_os_aggregate_lock.with_lock
      ?clock
      ~keepers_dir
      ~keeper_id
      (fun () ->
       (* File_lock_eio.with_lock appends ".lock" itself; a pre-suffixed path
          locked "<snapshot>.lock.lock" and left a stray file per keeper. *)
       File_lock_eio.with_lock ?clock snapshot_path (fun () ->
         let* previous, snapshot_content =
           match Fs_compat.load_file_opt snapshot_path with
           | None -> Ok (None, None)
           | Some content ->
             (match
                Domain_pool_ref.submit_cpu_or_inline (fun () ->
                  parse snapshot_path content)
              with
              | Ok snapshot -> Ok (Some snapshot, Some content)
              | Error rejection ->
                (* Every writer reads before it writes, so a snapshot this
                   build cannot decode is durable state no producer can leave:
                   one undecodable file wedged eight live keepers for good on
                   2026-09-01. #32239 declared a hard cut and left the old
                   files in place, and that is the half that was missing — a
                   hard cut is finished when the old state is gone.

                   The bytes move aside instead of being overwritten by the
                   commit below, because recovering by destroying the only copy
                   of the rejected state is not recovery. *)
                let* rejected_path =
                  quarantine_snapshot_and_receipt
                    ~keepers_dir ~keeper_id ~snapshot_path ~now ~rejection
                  |> Result.map_error store_error
                in
                Log.Keeper.warn
                  ~keeper_name:keeper_id
                  "memory os snapshot quarantined rejected_path=%s rejection=%s"
                  rejected_path
                  rejection;
                Ok (None, None))
         in
         let snapshot =
           match previous, snapshot_content with
           | Some current, Some content -> Some (current, content)
           | None, None -> None
           | Some _, None | None, Some _ -> None
         in
         let* () =
           reconcile_retraction_plan_receipt
             ~keepers_dir
             ~keeper_id
             ~snapshot
           |> Result.map_error store_error
         in
         let* durable_range_receipts =
           reconcile_durable_range_receipts
             ~keepers_dir
             ~keeper_id
             ~snapshot
           |> Result.map_error store_error
         in
         let* () =
           let consumed = List.filter_map (function
             | Committed {range_id; _} -> consumed_candidate range_id
             | Prepared _ -> None) durable_range_receipts in
           validate_unique_explicit_candidates (consumed @ explicit_candidate_ids)
           |> Result.map_error store_error
         in
         let* next, output = build ~snapshot_content previous in
         let applied_revision_links = List.filter (fun link ->
           links_applied_to_snapshot next [link]
           && Option.fold ~none:false ~some:(fun (prior : t) ->
             List.exists (fun fact -> memory_id fact = link.superseded) prior.facts) previous)
           declared_revisions in
         let* () = List.fold_left (fun result binding ->
           let* () = result in
           if not (List.mem binding.candidate_id explicit_candidate_ids) then
             Error (store_error "recall binding does not name a consumed candidate")
           else if not (List.exists (fun fact ->
             String.equal (memory_id fact) binding.target_memory_id) next.facts) then
             Error (store_error "recall binding target is absent from final Memory")
           else Ok ()) (Ok ()) admission_recall_bindings in
         (* [memory_id] hashes the claim text, so presence alone accepts a
            target the keeper retracted and re-added while the decision ran,
            and the binding would be born on the new incarnation after the
            retirement its readers look for. A target retired after the
            revision the decision read refuses the commit, and so does a
            journal that cannot show every revision written since; the input
            stays pending for a decision on current Memory. *)
         let* () = match admission_recall with
           | None | Some { bindings = []; _ } -> Ok ()
           | Some { decided_at_revision; bindings } ->
             let targets = Set_util.StringSet.of_list
               (List.map (fun binding -> binding.target_memory_id) bindings) in
             (match targets_retired_since ~keepers_dir ~keeper_id
                      ~revision:decided_at_revision
                      ~held:(Option.map (fun (current : t) -> current.revision) previous)
                      targets with
              | Error detail -> Error (store_error ("recall binding retirement check: " ^ detail))
              | Ok retired when Set_util.StringSet.is_empty retired -> Ok ()
              | Ok _ ->
                Error (store_error
                  "recall binding target was retired after the admission decision read Memory")) in
         let* source_lines =
           match
             Keeper_memory_source_current.read_for_keepers_dir
               ~keepers_dir
               ~keeper_id
           with
           | Error message -> Error (store_error message)
           | Ok snapshot ->
             let lines =
               Option.fold
                 ~none:[]
                 ~some:(fun (snapshot : Keeper_memory_source_current.t) ->
                   List.map
                     (Keeper_memory_source_current.render_fact ~verified:false)
                     snapshot.facts
                   @ List.map
                       Keeper_memory_source_current.render_invalidation
                       snapshot.invalidations)
                 snapshot
             in
             Ok lines
         in
         let previous_bytes =
           Keeper_memory_os_render.facts_payload_bytes
             ~ordinary_facts:
               (Option.fold ~none:[] ~some:(fun (snapshot : t) -> snapshot.facts) previous)
             ~source_lines
         in
         let* () =
           Keeper_memory_os_render.check_facts_budget
             ~previous_bytes
             ~ordinary_facts:next.facts
             ~source_lines
           |> Result.map_error store_error
         in
         let ranges =
           Option.to_list (Option.map (fun range -> Atom_range range) durable_range_id)
           @ Option.to_list (Option.map (fun range -> Official_range range) official_range_id)
           @ List.map (fun candidate ->
               match List.find_opt (fun binding -> binding.candidate_id = candidate) admission_recall_bindings with
               | None -> Explicit_candidate candidate
               | Some binding -> Explicit_candidate_with_recall binding) explicit_candidate_ids
         in
         let receipts_for make =
           List.fold_left (fun receipts range_id ->
             upsert_durable_range_receipt receipts (make range_id)) durable_range_receipts ranges
         in
         (* Locks and preparation remain cancellable. Once the pass starts to
            settle, retain its result and publish its evidence before
            cancellation can interrupt the journal/receipt writes for it. *)
         let protected settle =
           match Eio_guard.execution_context () with
           | Eio_guard.Non_eio -> settle ()
           | Eio_guard.Eio_fiber -> Eio.Cancel.protect settle
         in
         let log_invalidations ~revision =
           List.iter
             (fun invalidation ->
                Log.Keeper.info
                  "memory os support retracted keeper=%s revision=%d memory_id=%s missing_premise_ids=%s"
                  keeper_id
                  revision
                  (memory_id invalidation.fact)
                  (String.concat "," invalidation.missing_premise_ids))
             next.change.invalidated
         in
         (* A Librarian pass whose facts serialize to the stored ones, in the
            same order, changes nothing a reader of this store can see. Writing
            it anyway minted a revision, printed and replaced the whole file and
            woke every commit subscriber: on 2026-09-29, 1,600 of the 2,379
            Librarian commits (67%) added and removed nothing. Such a pass keeps
            the stored snapshot with its revision, bytes and [updated_at]. The
            comparison runs on the pool for the reason the print below does. *)
         let kept =
           match equal_facts, snapshot with
           | Write_revision _, (Some _ | None) | Keep_stored, None -> None
           | Keep_stored, Some (current, current_content) ->
             (* A kept fact is the stored value itself, so it compares without
                serializing; only a different value or count needs the bytes. *)
             let same_facts =
               Int.equal (List.compare_lengths current.facts next.facts) 0
               && Domain_pool_ref.submit_cpu_or_inline (fun () ->
                 List.equal
                   (fun left right ->
                      left == right
                      || String.equal (fact_payload left) (fact_payload right))
                   current.facts
                   next.facts)
             in
             if same_facts then Some (current, current_content) else None
         in
         match kept with
         | Some (current, current_content) ->
           (* [before_replace] still runs: it records what the pass did with its
              absorptions and claims, and with the same facts it has no row to
              write. *)
           let* () =
             match before_replace with
             | None -> Ok ()
             | Some write -> write ~previous ~next
           in
           let snapshot_sha256 = sha256 current_content in
           protected (fun () ->
             let+ () =
               match ranges with
               | [] -> Ok ()
               | _ :: _ ->
                 write_durable_range_receipts ~keepers_dir ~keeper_id
                   (receipts_for (fun range_id ->
                      Committed
                        { range_id; snapshot_revision = current.revision; snapshot_sha256 }))
                 |> Result.map_error store_error
             in
             Option.iter (fun observe -> observe current Unchanged) on_committed;
             (* The journal keeps one line per pass: the Librarian health view
                reads its newest Librarian line as the last success. This line
                names the revision that stays current. *)
             append_journal_entry
               ~commit_effect:Unchanged
               ~revision_links:[]
               ~keepers_dir
               ~keeper_id
               ~dropped_statements:
                 (Option.map (dropped_by_commit ~previous ~next) dropped_statements)
               { next with revision = current.revision };
             log_invalidations ~revision:current.revision;
             current, Unchanged, output)
         | None ->
         (* The file is 150-330 KB per keeper and every commit reads it, parses
            it, prints it and replaces it. On the scheduler domain that was one
            11-24 ms run per commit (rtev, 2026-09-16), about 80 commits an
            hour across the fleet; for the 330 KB file the parse is 2.6 ms and
            the print 5.4 ms. Both are pure over immutable values, so they run
            in pool jobs. The locks are held across the wait, which delays
            another writer of this same keeper's memory and nothing else. *)
         let content =
           Domain_pool_ref.submit_cpu_or_inline (fun () -> snapshot_bytes next)
         in
         (* Last before the replace, after the pool wait: a write made here and
            a snapshot that is then not replaced are split only by the replace
            failing, not by a cancellation while the print is on the pool. *)
         let* () =
           match before_replace with
           | None -> Ok ()
           | Some write -> write ~previous ~next
         in
         let snapshot_sha256 = sha256 content in
         let committed_dropped =
           Option.map (dropped_by_commit ~previous ~next) dropped_statements
         in
         let* () =
           match retraction_plan with
           | None -> Ok ()
           | Some (plan_id, _) ->
             (match next.source with
              | { kind = Explicit_retract; trace_id }
                when String.equal trace_id plan_id -> Ok ()
              | _ ->
                Error
                  (store_error
                     "retraction plan source must be an exact explicit-retract plan"))
         in
         let* retraction_receipt =
           match snapshot, committed_dropped with
           | Some (prior, prior_content), reasons
             when applied_revision_links <> [] || Option.fold ~none:false ~some:((<>) []) reasons ->
             let reasons = Option.value ~default:[] reasons in
             let receipt =
               { plan_id = Option.map fst retraction_plan
               ; prior_revision = prior.revision
               ; prior_snapshot_sha256 = sha256 prior_content
               ; target_revision = next.revision
               ; target_snapshot_sha256 = snapshot_sha256
               ; dropped_statements = reasons
               ; revision_links = applied_revision_links
               }
             in
             let+ () =
               write_retraction_plan_receipt
                 ~keepers_dir
                 ~keeper_id
                 receipt
               |> Result.map_error store_error
             in
             Some receipt
           | None, _ | Some _, _ ->
             (match retraction_plan with
              | None -> Ok None
              | Some _ ->
                Error
                  (store_error
                     "retraction plan requires one existing snapshot and non-empty exact reasons"))
         in
         let* () =
           match ranges with
           | [] -> Ok ()
           | _ :: _ ->
             write_durable_range_receipts ~keepers_dir ~keeper_id
               (receipts_for (fun range_id ->
                  Prepared { range_id; snapshot_revision = next.revision; snapshot_sha256 }))
             |> Result.map_error store_error
         in
         let commit () =
           match Fs_compat.save_file_atomic snapshot_path content with
           | Ok () ->
             committed := Some
               { Keeper_memory_commit_notifications.keepers_dir = notification_keepers_dir
               ; keeper_id
               ; store = Ordinary
               ; revision = next.revision
             };
             Option.iter (fun observe -> observe next Rewritten) on_committed;
             let journal_result =
               match retraction_receipt, retraction_plan with
               | None, _ ->
                 append_journal_entry
                   ~commit_effect:Rewritten
                   ~revision_links:applied_revision_links
                   ~keepers_dir
                   ~keeper_id
                   ~dropped_statements:committed_dropped
                   next;
                 Ok ()
               | Some receipt, Some (plan_id, evidence_error) ->
                 (* This commit has not appended its line yet. Only restart
                    reconciliation needs to scan the historical journal. *)
                 append_removal_journal_and_clear_receipt
                   ~keepers_dir ~keeper_id ~snapshot:next receipt
                 |> Result.map_error (fun detail ->
                      evidence_error
                        ~plan_id
                        ~snapshot_revision:receipt.target_revision
                        ~snapshot_sha256:receipt.target_snapshot_sha256
                        ~detail)
               | Some receipt, None ->
                 (* The snapshot committed. Preserve that outcome for the
                    producer while retaining the receipt and the removed
                    originals in [next.change]. Every later writer must
                    finalize their journal before replacing this snapshot. *)
                 (match
                    append_removal_journal_and_clear_receipt
                      ~keepers_dir ~keeper_id ~snapshot:next receipt
                  with
                  | Ok () -> ()
                  | Error detail ->
                    Log.Keeper.warn
                      ~keeper_name:keeper_id
                      "memory snapshot committed revision=%d; archive journal finalization pending; removal receipt and originals remain preserved: %s"
                      receipt.target_revision
                      detail);
                 Ok ()
             in
             (match ranges with
              | [] -> ()
              | _ :: _ ->
                (match write_durable_range_receipts ~keepers_dir ~keeper_id
                   (receipts_for (fun range_id ->
                      Committed { range_id; snapshot_revision = next.revision; snapshot_sha256 }))
                 with
                 | Ok () -> ()
                 | Error detail ->
                   Log.Keeper.warn ~keeper_name:keeper_id
                     "%s; prepared receipt remains recoverable" detail));
             let+ () = journal_result in
             log_invalidations ~revision:next.revision;
             next, Rewritten, output
           | Error message ->
             Error
               (store_error
                  (Printf.sprintf
                     "current Memory OS atomic write failed path=%s: %s"
                     snapshot_path
                     message))
         in
         protected commit))
    in
    (* Dispatch only after BOTH locks have unwound. The marker is set at the
       snapshot commit, so a later journal failure/cancellation cannot suppress
       an already committed change or make a failed write look committed. *)
    match write () with
    | result -> notify (); result
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      notify ();
      Printexc.raise_with_backtrace exn backtrace)
;;

(* Explicit writes always write a revision, so their effect is [Rewritten].
   Supersession carries its own decision through the commit. *)
let update_locked_with_error
      ?clock
      ?dropped_statements
      ?retraction_plan
      ~store_error
      ~keepers_dir
      ~keeper_id
      ~now
      build
  =
  update_locked_with_output
    ?clock ?dropped_statements
    ~equal_facts:(Write_revision retraction_plan) ~store_error ~keepers_dir ~keeper_id ~now
    (fun ~snapshot_content previous ->
       let+ next = build ~snapshot_content previous in
       next, ())
  |> Result.map (fun (snapshot, (_ : commit_effect), ()) -> snapshot)
;;

type receipt_read = Reconcile_receipts | Preserve_authority of string

(* Admission cannot reinterpret a consumed input as new when its snapshot proof
   disappears. This read projects prepared commits in memory only, preserving
   every stored byte even when the caller subsequently rejects queue coverage. *)
let preserved_committed_receipts ~keepers_dir ~keeper_id ~snapshot ~queue_generation =
  let* receipts = read_durable_range_receipts ~keepers_dir ~keeper_id in
  let receipts = List.filter (fun receipt ->
    match consumed_candidate (receipt_range_id receipt) with
    | Some candidate -> String.equal candidate.queue_generation queue_generation
    | None -> false) receipts in
  let rec verify kept = function
    | [] -> Ok (List.rev kept)
    | Prepared {range_id; snapshot_revision; snapshot_sha256} :: rest ->
      (match snapshot with
       | Some (current, content) when current.revision = snapshot_revision
           && String.equal (sha256 content) snapshot_sha256 ->
         verify (Committed {range_id; snapshot_revision; snapshot_sha256} :: kept) rest
       | None | Some _ -> verify kept rest)
    | (Committed {snapshot_revision; snapshot_sha256; _} as receipt) :: rest ->
      (match snapshot with
       | Some (current, content) when current.revision > snapshot_revision
           || (current.revision = snapshot_revision && String.equal (sha256 content) snapshot_sha256) ->
         verify (receipt :: kept) rest
       | None | Some _ -> Error "explicit admission authority unavailable: committed receipt has no verifiable current snapshot; stores preserved") in
  verify [] receipts
;;

let with_receipt_status ?(strict_snapshot=false) ?(receipt_read=Reconcile_receipts) ~keepers_dir ~keeper_id select =
  try
    Fs_compat.mkdir_p keepers_dir;
    let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
      File_lock_eio.with_lock snapshot_path (fun () ->
        let* snapshot =
          match Fs_compat.load_file_opt snapshot_path with
          | None -> Ok None
          | Some content ->
            (match parse snapshot_path content with
             | Ok current -> Ok (Some (current, content))
             | Error rejection when strict_snapshot -> Error rejection
             | Error rejection ->
               (* A receipt is evidence for skipping already-committed work, so
                  an unverifiable receipt must read as no receipt, never as an
                  honored one: this caller proceeds and re-commits, and the
                  write path's quarantine branch repairs the undecodable bytes
                  (#32461). Failing the whole check here stopped every pass in
                  front of a broken snapshot, which is the wedge itself. An I/O
                  failure above still raises out of the try. *)
               Log.Keeper.warn
                 ~keeper_name:keeper_id
                 "range receipt check cannot decode the current snapshot; treating its receipts as unverifiable: %s"
                 rejection;
               Ok None)
        in
        let receipts =
          try
            match receipt_read with
            | Reconcile_receipts -> reconcile_durable_range_receipts ~keepers_dir ~keeper_id ~snapshot
            | Preserve_authority queue_generation ->
                preserved_committed_receipts ~keepers_dir ~keeper_id ~snapshot ~queue_generation
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printf.sprintf
              "durable receipt reconciliation failed: %s" (Printexc.to_string exn))
        in
        select (Option.map fst snapshot) receipts))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "durable Librarian range receipt check failed keeper=%s: %s"
         keeper_id
         (Printexc.to_string exn))
;;

let with_committed_receipts ?(strict_snapshot=false) ?(receipt_read=Reconcile_receipts) ~keepers_dir ~keeper_id select =
  with_receipt_status ~strict_snapshot ~receipt_read ~keepers_dir ~keeper_id (fun snapshot receipts ->
    let* receipts = receipts in
    select snapshot receipts)
;;

type revision_evidence =
  { snapshot_revision : int
  ; recorded_at : float
  ; source : source
  ; commit_effect : commit_effect option
  ; revision_links : revision list option
  ; removed_memory_ids : string list
  ; added_memory_ids : string list
  }

let read_with_revision_evidence_for_keepers_dir ~keepers_dir ~keeper_id ~after_revision =
  if after_revision < 0 then Error "revision evidence starting revision must be nonnegative"
  else with_committed_receipts ~strict_snapshot:true ~keepers_dir ~keeper_id
    (fun snapshot _receipts ->
      let* pending = read_retraction_plan_receipt ~keepers_dir ~keeper_id in
      match pending with
      | Some _ -> Error "revision evidence journal finalization is pending"
      | None ->
        let rows = ref [] in
        let visit = function
          | Dated_jsonl.Malformed_json {detail; _} -> Some (Error detail)
          | Dated_jsonl.Parsed json ->
            match journal_entry_of_json json with
            | Error detail -> Some (Error detail)
            | Ok (Journal_failed _ | Journal_quarantined _) -> None
            | Ok (Journal_committed {revision; recorded_at; source; change; _}) ->
              if revision <= after_revision then Some (Ok ())
              else match snapshot, json with
                | Some current, `Assoc fields when revision <= current.revision ->
                  (match journal_commit_effect fields, journal_revision_links fields with
                   | Ok commit_effect, Ok revision_links ->
                     rows := {snapshot_revision=revision; recorded_at; source; commit_effect;
                       revision_links; removed_memory_ids=List.map memory_id change.removed;
                       added_memory_ids=List.map memory_id change.added} :: !rows;
                     None
                   | Error detail, _ | _, Error detail -> Some (Error detail))
                | _ -> Some (Error "revision evidence exceeds the current snapshot") in
        let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
        let* result = Domain_pool_ref.submit_io_or_inline (fun () ->
          Dated_jsonl.find_latest_entry_in_file_result path visit)
          |> Result.map_error Dated_jsonl.read_error_to_string in
        let+ () = match result with None -> Ok () | Some result -> result in
        snapshot, !rows)
;;

let committed_range ~keepers_dir ~keeper_id select =
  with_committed_receipts ~keepers_dir ~keeper_id (fun _snapshot receipts ->
    Ok (List.find_map (function
      | Committed {range_id; _} -> select range_id
      | Prepared _ -> None) receipts))
;;

let committed_explicit_candidates ~keepers_dir ~keeper_id ~queue_generation =
  with_committed_receipts ~receipt_read:(Preserve_authority queue_generation) ~keepers_dir ~keeper_id (fun _snapshot receipts ->
    Ok (List.filter_map (function
      | Committed {range_id; _} ->
        (match consumed_candidate range_id with
         | Some candidate when String.equal candidate.queue_generation queue_generation -> Some candidate
         | Some _ | None -> None)
      | Prepared _ -> None) receipts
    |> List.sort (fun (left : explicit_candidate_id) right -> Int.compare left.sequence right.sequence)))
;;

(* Bindings are only recalled in the incarnation they were committed against.
   The snapshot hash proves the binding's birth; complete later journal revisions
   prove no intervening retirement, even if the exact claim was re-added. *)
let read_recall_journal_projection ~path ~oldest =
      let inspect () =
        try Ok (Unix.lstat path) with
        | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error) in
      let* before = inspect () in
      let cached = Identity_map.find_opt path (Atomic.get recall_journal_cache) in
      match cached with
        | Some cached when cached.oldest=oldest && same_file_identity cached.identity before ->
          Ok cached.projection
        | Some _ | None ->
          (* Growth is not proof of an append. Only the normal local writer's
             locked observation may advance the cached identity; any external
             change requires the complete authoritative history again. *)
          publish_recall_cache path None;
          let* scanned = Dated_jsonl.fold_file_appended_entries_result path ~cursor:None
            ~init:empty_recall_projection ~f:(project_recall_entry ~oldest)
            |> Result.map_error Dated_jsonl.read_error_to_string in
          let* projection = match scanned with
            | Dated_jsonl.Appended (projection, _) -> Ok projection
            | Dated_jsonl.Cursor_invalidated -> Error "admission recall cold journal cursor invalidated" in
          let* after = inspect () in
          if not (same_file_identity before after) then
            Error "admission recall journal changed during full verification"
          else (
            publish_recall_cache path (Some {oldest;identity=after;projection});
            Ok projection)
;;

let live_admission_bindings ~keepers_dir ~keeper_id (snapshot : t) bindings =
  let current_ids = Set_util.StringSet.of_list (List.map memory_id snapshot.facts) in
  let applicable = List.filter (fun (_, binding) ->
    Set_util.StringSet.mem binding.target_memory_id current_ids) bindings in
  let oldest = List.fold_left (fun oldest (revision, _) -> min oldest revision)
    snapshot.revision applicable in
  if oldest = snapshot.revision then Ok (List.map snd applicable)
  else
    Domain_pool_ref.submit_io_or_inline (fun () ->
      let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
      let* projection = read_recall_journal_projection ~path ~oldest in
      let* () = match projection.invalid with None -> Ok () | Some detail -> Error detail in
      if projection.highest > snapshot.revision then
        Error "admission recall journal is ahead of the current snapshot"
      else if Recall_revision_set.cardinal projection.revisions <> snapshot.revision - oldest then
        Error "admission recall lacks complete intervening Memory revision history"
      else Ok (List.filter_map (fun (born_revision, binding) ->
        match Identity_map.find_opt binding.target_memory_id projection.retired with
        | Some removed_revision when removed_revision > born_revision -> None
        | Some _ | None -> Some binding) applicable))
;;

let read_with_admission_recall_status_for_keepers_dir ~keepers_dir ~keeper_id =
  with_receipt_status ~strict_snapshot:true ~keepers_dir ~keeper_id
    (fun snapshot receipts ->
      match snapshot, receipts with
      | snapshot, Error detail -> Ok (snapshot, Error detail)
      | None, Ok _ -> Ok (None, Ok [])
      | Some current, Ok receipts ->
        let bindings = List.filter_map (function
          | Committed {range_id=Explicit_candidate_with_recall binding; snapshot_revision; _} ->
            Some (snapshot_revision, binding)
          | Committed _ | Prepared _ -> None) receipts in
        Ok (Some current, live_admission_bindings ~keepers_dir ~keeper_id current bindings))
;;

let read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id =
  let* snapshot, bindings =
    read_with_admission_recall_status_for_keepers_dir ~keepers_dir ~keeper_id in
  let+ bindings = bindings in
  snapshot, bindings
;;

type recall_unresolved_reason =
  | History_unavailable of string
  | Missing_transition of int
  | Invalid_transition of int
  | Unrecorded_lineage of int
  | Retired_without_successor of int

type recall_unresolved =
  { binding : admission_recall_binding
  ; reason : recall_unresolved_reason
  }

type successor_recall_candidate =
  { binding : admission_recall_binding
  ; born_revision : int
  ; original_target : Keeper_memory_os_types.fact
  ; target : Keeper_memory_os_types.fact
  ; path : revision_evidence list
  }

type successor_recall =
  { receipt_verification : (unit, string) result
  ; snapshot : t option
  ; direct_bindings : admission_recall_binding list
  ; successor_candidates : successor_recall_candidate list
  ; unresolved : recall_unresolved list
  }

let revision_evidence_to_json (row : revision_evidence) =
  `Assoc ["snapshot_revision", `Int row.snapshot_revision; "recorded_at", `Float row.recorded_at;
    "source", source_to_json row.source;
    "commit_effect", (match row.commit_effect with None -> `Null
      | Some Rewritten -> `String "rewritten" | Some Unchanged -> `String "unchanged");
    "revision_links", (match row.revision_links with None -> `Null | Some links -> revision_links_to_json links);
    "removed_memory_ids", `List (List.map (fun id -> `String id) row.removed_memory_ids);
    "added_memory_ids", `List (List.map (fun id -> `String id) row.added_memory_ids)]
;;

let recall_unresolved_reason_to_string = function
  | History_unavailable detail -> "history unavailable: " ^ detail
  | Missing_transition revision -> Printf.sprintf "missing transition at revision %d" revision
  | Invalid_transition revision -> Printf.sprintf "invalid transition at revision %d" revision
  | Unrecorded_lineage revision -> Printf.sprintf "lineage unrecorded at revision %d" revision
  | Retired_without_successor revision -> Printf.sprintf "retired without successor at revision %d" revision
;;

let recall_unresolved_reason_to_json reason =
  let kind, fields = match reason with
    | History_unavailable detail -> "history_unavailable", ["detail", `String detail]
    | Missing_transition revision -> "missing_transition", ["revision", `Int revision]
    | Invalid_transition revision -> "invalid_transition", ["revision", `Int revision]
    | Unrecorded_lineage revision -> "unrecorded_lineage", ["revision", `Int revision]
    | Retired_without_successor revision -> "retired_without_successor", ["revision", `Int revision] in
  `Assoc (("kind", `String kind) :: fields)
;;

type recall_transition = { evidence : revision_evidence; removed : fact list }

let read_recall_transitions ~keepers_dir ~keeper_id ~after_revision ~through_revision =
  let* pending = read_retraction_plan_receipt ~keepers_dir ~keeper_id in
  match pending with
  | Some _ -> Error "successor recall journal finalization is pending"
  | None ->
    Domain_pool_ref.submit_io_or_inline (fun () ->
      let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
      let* projection = read_recall_journal_projection ~path ~oldest:after_revision in
      let* () = match projection.invalid with None -> Ok () | Some detail -> Error detail in
      if projection.highest > through_revision then Error "journal exceeds current revision"
      else
        (* Keep every actual rewrite, including duplicate revisions: the pure
           validator must still distinguish equal replay from conflicting
           transition evidence. Unchanged observations cannot supply edges. *)
        let rec decode acc = function
          | [] -> Ok (List.rev acc)
          | json :: rest ->
            let* entry = journal_entry_of_json json in
            match entry, json with
            | Journal_committed {revision;recorded_at;source;change;_}, `Assoc fields ->
              let* commit_effect = journal_commit_effect fields in
              let* revision_links = journal_revision_links fields in
              let row = {evidence={snapshot_revision=revision;recorded_at;source;commit_effect;
                revision_links;removed_memory_ids=List.map memory_id change.removed;
                added_memory_ids=List.map memory_id change.added};removed=change.removed} in
              decode (row::acc) rest
            | _ -> Error "cached rewrite is not a committed journal record" in
        decode [] (List.rev projection.rewrites_rev))
;;

(* Pure chronological projection. Each path follows one incarnation; only a
   declared edge at its retirement can continue it. Unrelated later additions
   cannot restart a path that was removed from the frontier. *)
let project_successor_recall (current : t) bindings history =
  let transitions = match history with
    | Error _ -> []
    | Ok rows -> List.filter (fun row -> row.evidence.commit_effect=Some Rewritten) rows in
  (* Reconstruct each transition's after-state from current identities. A
     later unrelated addition must not make an earlier phantom edge live. *)
  let after_states = Hashtbl.create 16 in
  let active = ref (Set_util.StringSet.of_list (List.map memory_id current.facts)) in
  List.rev transitions |> List.iter (fun row ->
    let revision = row.evidence.snapshot_revision in
    if not (Hashtbl.mem after_states revision) then (
      Hashtbl.add after_states revision !active;
      let before_additions = List.fold_left (fun ids id -> Set_util.StringSet.remove id ids)
        !active row.evidence.added_memory_ids in
      active := List.fold_left (fun ids id -> Set_util.StringSet.add id ids)
        before_additions row.evidence.removed_memory_ids));
  let direct = ref [] and candidates = ref [] and unresolved = ref [] in
  List.iter (fun (born_revision, (binding : admission_recall_binding)) ->
    let note reason = unresolved := {binding; reason} :: !unresolved in
    let later = List.filter (fun row -> row.evidence.snapshot_revision > born_revision) transitions in
    let rec validate expected acc = function
      | [] -> if expected = current.revision then Ok (List.rev acc)
        else Error (Missing_transition (expected+1))
      | row :: rest ->
        let revision = row.evidence.snapshot_revision in
        if revision = expected then
          (match acc with
           | prior :: _ when prior = row -> validate expected acc rest
           | _ -> Error (Invalid_transition revision))
        else if revision <> expected+1 then Error (Missing_transition (expected+1))
        else validate revision (row::acc) rest in
    let coverage = if born_revision=current.revision then Ok [] else
      match history with Error detail -> Error (History_unavailable detail)
      | Ok _ -> validate born_revision [] later in
    match coverage with
    | Error reason -> note reason
    | Ok rows ->
      let frontier = List.fold_left (fun frontier row ->
        List.concat_map (fun (identity, original, path) ->
          if not (List.mem identity row.evidence.removed_memory_ids)
             || List.mem identity row.evidence.added_memory_ids then [identity, original, path]
          else
            match List.find_opt (fun fact -> memory_id fact=identity) row.removed with
            | None -> note (Invalid_transition row.evidence.snapshot_revision); []
            | Some removed ->
              match row.evidence.revision_links with
              | None -> note (Unrecorded_lineage row.evidence.snapshot_revision); []
              | Some links ->
                let successors = List.filter (fun (link : revision) -> link.superseded=identity) links in
                if successors=[] then (note (Retired_without_successor row.evidence.snapshot_revision); [])
                else List.filter_map (fun (link : revision) ->
                  let after = Hashtbl.find after_states row.evidence.snapshot_revision in
                  if Set_util.StringSet.mem identity after
                     || not (Set_util.StringSet.mem link.superseded_by after) then (
                    note (Invalid_transition row.evidence.snapshot_revision); None)
                  else Some (link.superseded_by,
                    (match original with None -> Some removed | Some _ -> original),
                    row.evidence::path)) successors) frontier
        |> List.sort_uniq compare) [binding.target_memory_id,None,[]] rows in
      List.iter (fun (identity, original, path) ->
        match List.find_opt (fun fact -> memory_id fact=identity) current.facts with
        | None -> note (Invalid_transition current.revision)
        | Some target ->
          match original, path with
          | None, [] -> direct := binding :: !direct
          | Some original_target, _ :: _ ->
            candidates := {binding; born_revision; original_target; target; path=List.rev path} :: !candidates
          | None, _ :: _ | Some _, [] -> note (Invalid_transition current.revision)) frontier) bindings;
  {receipt_verification=Ok (); snapshot=Some current; direct_bindings=List.rev !direct;
   successor_candidates=List.rev !candidates; unresolved=List.sort_uniq compare !unresolved}
;;

let read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id =
  with_receipt_status ~strict_snapshot:true ~keepers_dir ~keeper_id (fun snapshot receipts ->
    match snapshot, receipts with
    | snapshot, Error detail -> Ok {receipt_verification=Error detail; snapshot;
        direct_bindings=[]; successor_candidates=[]; unresolved=[]}
    | None, Ok _ -> Ok {receipt_verification=Ok (); snapshot=None; direct_bindings=[]; successor_candidates=[]; unresolved=[]}
    | Some current, Ok receipts ->
      let bindings = List.filter_map (function
        | Committed {range_id=Explicit_candidate_with_recall binding; snapshot_revision; _} ->
          Some (snapshot_revision,binding)
        | Committed _ | Prepared _ -> None) receipts in
      let oldest = List.fold_left (fun earliest (revision, _) -> min earliest revision)
        current.revision bindings in
      let history = if oldest=current.revision then Ok [] else
        read_recall_transitions ~keepers_dir ~keeper_id ~after_revision:oldest ~through_revision:current.revision in
      Ok (project_successor_recall current bindings history))
;;

let committed_durable_range ~keepers_dir ~keeper_id ~receipt_scope =
  committed_range ~keepers_dir ~keeper_id (function
    | Atom_range range when String.equal range.receipt_scope receipt_scope -> Some range
    | Atom_range _ | Official_range _ | Explicit_candidate _ | Explicit_candidate_with_recall _ -> None)
;;

let committed_official_range ~keepers_dir ~keeper_id ~receipt_scope =
  committed_range ~keepers_dir ~keeper_id (function
    | Official_range range when String.equal range.receipt_scope receipt_scope -> Some range
    | Atom_range _ | Official_range _ | Explicit_candidate _ | Explicit_candidate_with_recall _ -> None)
;;

(* Apply a librarian's disposition to whatever the snapshot holds when the
   lock is taken.

   The librarian says three things about the facts it was shown: keep this one,
   retire that one for this reason, add these new claims. Those statements are
   what it decided; the whole-set list it also carries is a projection of them
   against the snapshot it read, and projecting early is what forced the write
   to demand that nothing had changed since. A keeper recording one fact of its
   own during the pass moved the revision and the pass was thrown away -- 758
   times on the fleet, 590 of them in one week (masc #32859).

   A fact the disposition never mentions is one the librarian never saw, so it
   is left alone. That is the whole difference.

   A fact the librarian retires is retired even if the keeper re-observed it
   during the pass: the judgment was about the claim, and a re-observation does
   not answer it. The keeper can state it again on its next turn. *)
type disposition =
  { snapshot : t
  ; commit : commit_effect
  ; absorbed_applied : Keeper_memory_os_types.absorbed_statement list
  ; absorbed_not_applied : Keeper_memory_os_types.absorbed_statement list
  ; claims_not_applied : Keeper_memory_os_types.fact list
  ; revisions_applied : Keeper_memory_os_types.revision list
  }

(* What one commit does with the answer, decided from the snapshot the lock
   holds. Computed by the update and again by [before_replace] from the same
   locked snapshot, so both see the same decision. *)
type disposition_plan =
  { claims_accepted : Keeper_memory_os_types.fact list
  ; claims_refused : Keeper_memory_os_types.fact list
  ; plan_retired : Set_util.StringSet.t
  ; absorbed_into : string Set_util.StringMap.t
  }

let apply_disposition
      ?on_committed
      ?clock
      ?dropped_statements
      ?durable_range_id
      ?official_range_id
      ?(explicit_candidate_ids = [])
      ?admission_recall
      ?(required_memory_ids = [])
      ~absorbed
      ~revisions
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      ~new_claims
      ()
  =
  let ids_of facts =
    List.fold_left
      (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
      Set_util.StringSet.empty
      facts
  in
  let retired =
    List.fold_left
      (fun ids (statement : Keeper_memory_os_types.dropped_statement) ->
         Set_util.StringSet.add statement.memory_id ids)
      Set_util.StringSet.empty
      (Option.value dropped_statements ~default:[])
  in
  (* The librarian read the snapshot before its provider turn, so a memory its
     answer continues may be gone by the time the lock is taken: the keeper
     retracted it, or superseded it with a successor of its own (#38122).

     A new claim that supersedes such a memory, or absorbs one, is not stored:
     it would carry on content the keeper already removed or replaced, and the
     old id would get a second successor. A memory the answer supersedes
     leaves only when one of its successors is in the next snapshot: a stored
     new claim, or a restated memory the locked snapshot still holds. Its only
     reason to leave was that successor.

     An absorption goes into a memory the answer names: a stored new claim, or
     a current memory it wrote again verbatim. An absorption whose target is
     neither held by the locked snapshot nor stored by this answer is not
     applied: its source stays current, a removed memory is not brought back,
     and no absorbed row points into an id no snapshot has (#38186). *)
  let plan_of (previous : t option) =
    let current_ids =
      match previous with
      | None -> Set_util.StringSet.empty
      | Some snapshot -> ids_of snapshot.facts
    in
    let held identity = Set_util.StringSet.mem identity current_ids in
    let continues_a_removed_memory fact =
      let identity = memory_id fact in
      (not (held identity))
      && (List.exists
            (fun (revision : Keeper_memory_os_types.revision) ->
               String.equal revision.superseded_by identity
               && not (held revision.superseded))
            revisions
          || List.exists
               (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
                  String.equal statement.into identity && not (held statement.absorbed))
               absorbed)
    in
    let claims_refused, claims_accepted =
      List.partition continues_a_removed_memory new_claims
    in
    let accepted_ids = ids_of claims_accepted in
    let plan_retired =
      Set_util.StringSet.filter
        (fun identity ->
           let successors =
             List.filter
               (fun (revision : Keeper_memory_os_types.revision) ->
                  String.equal revision.superseded identity)
               revisions
           in
           match successors with
           | [] -> true
           | _ :: _ ->
             List.exists
               (fun (revision : Keeper_memory_os_types.revision) ->
                  held revision.superseded_by
                  || Set_util.StringSet.mem revision.superseded_by accepted_ids)
               successors)
        retired
    in
    let absorbed_into =
      List.fold_left
        (fun into_of (statement : Keeper_memory_os_types.absorbed_statement) ->
           if held statement.into || Set_util.StringSet.mem statement.into accepted_ids
           then Set_util.StringMap.add statement.absorbed statement.into into_of
           else into_of)
        Set_util.StringMap.empty
        absorbed
    in
    { claims_accepted; claims_refused; plan_retired; absorbed_into }
  in
  (* What the commit did: an absorption is applied when its row is written (its
     source left the snapshot into its target), a revision when its old id left
     the snapshot and its successor is in the next one. Set by the one
     [before_replace] under the lock, which runs on every commit; read only
     after the commit succeeded. *)
  let outcome = ref (([], absorbed), [], []) in
  let disposition_of snapshot commit =
    let (absorbed_applied, absorbed_not_applied), claims_not_applied, revisions_applied =
      !outcome
    in
    { snapshot
    ; commit
    ; absorbed_applied
    ; absorbed_not_applied
    ; claims_not_applied
    ; revisions_applied
    }
  in
  (* RFC-0456 §4.2: an absorbed fact leaves the snapshot only with its row kept.
     The rows are the absorbed facts the locked snapshot held and the next one
     does not, so a fact the keeper retracted during the pass has no row, and
     they are written just before the replace; a failed write fails this
     commit. *)
  let write_absorbed_rows ~(previous : t option) ~(next : t) =
    let plan = plan_of previous in
    let previous_facts =
      match previous with
      | None -> []
      | Some snapshot -> snapshot.facts
    in
    let previous_ids = ids_of previous_facts in
    let next_ids = ids_of next.facts in
    let rows =
      List.filter_map
        (fun fact ->
           let identity = memory_id fact in
           match Set_util.StringMap.find_opt identity plan.absorbed_into with
           | Some into when not (Set_util.StringSet.mem identity next_ids) ->
             Some
               { Keeper_memory_absorbed.recorded_at = now
               ; trace_id = (source : source).trace_id
               ; memory_id = identity
               ; into
               ; fact
               }
           | Some _ | None -> None)
        previous_facts
    in
    let revisions_applied =
      List.filter
        (fun (revision : Keeper_memory_os_types.revision) ->
           Set_util.StringSet.mem revision.superseded previous_ids
           && (not (Set_util.StringSet.mem revision.superseded next_ids))
           && Set_util.StringSet.mem revision.superseded_by next_ids)
        revisions
    in
    outcome
    := ( List.partition
           (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
              List.exists
                (fun (row : Keeper_memory_absorbed.record) ->
                   String.equal row.memory_id statement.absorbed
                   && String.equal row.into statement.into)
                rows)
           absorbed
       , plan.claims_refused
       , revisions_applied );
    Keeper_memory_absorbed.append_all ~keepers_dir ~keeper_id rows
    |> Result.map_error Keeper_memory_absorbed.append_error_to_string
  in
  update_locked_with_output
    ?on_committed:
      (Option.map
         (fun on_committed snapshot commit -> on_committed (disposition_of snapshot commit))
         on_committed)
    ?clock
    ?dropped_statements
    ?durable_range_id
    ?official_range_id
    ~explicit_candidate_ids
    ?admission_recall
    ~declared_revisions:revisions
    ~before_replace:write_absorbed_rows
    ~equal_facts:Keep_stored
    ~store_error:Fun.id
    ~keepers_dir
    ~keeper_id
    ~now
    (fun ~snapshot_content:_ previous ->
       let current =
         match previous with
         | None -> []
         | Some snapshot -> snapshot.facts
       in
       let plan = plan_of previous in
       let kept =
         List.filter
           (fun fact ->
              let identity = memory_id fact in
              not
                (Set_util.StringSet.mem identity plan.plan_retired
                 || Set_util.StringMap.mem identity plan.absorbed_into))
           current
       in
       (* The store rejects a repeated identity outright, so a claim the keeper
          already wrote during the pass is not appended a second time. *)
       let added, _ =
         List.fold_left
           (fun (acc, seen) fact ->
              let identity = memory_id fact in
              if Set_util.StringSet.mem identity seen
              then acc, seen
              else fact :: acc, Set_util.StringSet.add identity seen)
           ([], ids_of kept)
           plan.claims_accepted
       in
       let* next = make_snapshot ~previous ~now ~source ~facts:(kept @ List.rev added) () in
       let actual = ids_of next.facts in
       match List.find_opt (fun identity -> not (Set_util.StringSet.mem identity actual)) required_memory_ids with
       | Some identity -> Error ("explicit admission destination is not current: " ^ identity)
       | None -> Ok (next, ()))
  |> Result.map (fun (snapshot, commit, ()) -> disposition_of snapshot commit)
;;

let replace
      ?clock
      ?dropped_statements
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      ~now
      ~source
      ~facts
      ()
  =
  update_locked_with_error
    ?clock
    ?dropped_statements
    ~store_error:Fun.id
    ~keepers_dir
    ~keeper_id
    ~now
    (fun ~snapshot_content:_ previous ->
    let observed_revision =
      Option.map (fun snapshot -> snapshot.revision) previous
    in
    if observed_revision <> expected_revision
    then
      Error
        (Printf.sprintf
           "current Memory OS revision conflict expected=%s observed=%s"
           (Option.fold ~none:"absent" ~some:string_of_int expected_revision)
           (Option.fold ~none:"absent" ~some:string_of_int observed_revision))
    else
      make_snapshot
        ~previous
        ~now
        ~source
        ~facts
        ())
;;

(* One incoming fact added to a fact list: new claim bytes are appended,
   bytes already present are a re-observation of that row. Shared by
   {!upsert_fact} and {!supersede_fact}, so both give a row the same
   [first_seen] and [last_seen]. *)
let upsert_fact ?clock ~keepers_dir ~keeper_id ~now ~source incoming =
  update_locked_with_error
    ?clock
    ~store_error:(fun detail -> Upsert_persistence_failed detail)
    ~keepers_dir ~keeper_id ~now
    (fun ~snapshot_content:_ previous -> upsert_snapshot ~previous ~now ~source incoming)
;;

let retract_current_facts ~target_ids current_facts =
  match
    Set_util.StringSet.to_seq target_ids
    |> Seq.find_map (fun target_memory_id ->
         if
           List.exists
             (fun fact ->
                String.equal
                  (Keeper_memory_os_types.memory_id fact)
                  target_memory_id)
             current_facts
         then None
         else Some target_memory_id)
  with
  | Some missing -> Error missing
  | None ->
    let candidates =
      List.filter
        (fun fact ->
           not
             (Set_util.StringSet.mem
                (Keeper_memory_os_types.memory_id fact)
                target_ids))
        current_facts
    in
    Ok (maintain_supported_facts candidates)
;;

let retract_fact
      ?clock
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      ~memory_id:target_memory_id
      ~reason
      ()
  =
  if not (Keeper_memory_os_types.is_memory_id target_memory_id)
  then Error Retract_memory_id_invalid
  else if String.equal (String.trim reason) ""
  then Error Retract_reason_empty
  else
    update_locked_with_error
      ?clock
      ~dropped_statements:
        [ { Keeper_memory_os_types.memory_id = target_memory_id; reason } ]
      ~store_error:(fun detail -> Retract_persistence_failed detail)
      ~keepers_dir
      ~keeper_id
      ~now
      (fun ~snapshot_content:_ previous ->
      let current_facts =
        match previous with
        | None -> []
        | Some snapshot -> snapshot.facts
      in
      let* facts, invalidated =
        retract_current_facts
          ~target_ids:(Set_util.StringSet.singleton target_memory_id)
          current_facts
        |> Result.map_error (fun missing -> Retract_fact_not_found missing)
      in
        make_snapshot_from_maintained
          ~previous
          ~now
          ~source
          ~facts
          ~invalidated
          ()
        |> Result.map_error (fun detail -> Retract_persistence_failed detail))
;;

(* A supersession is a retraction and a write that must not be seen apart: a
   reader between the two would find either both claims or neither. So the
   target leaves and the successor arrives in one locked update, and the
   successor goes through the same [insert_or_reobserve] an ordinary write
   does. *)
let supersede_fact
      ?clock
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      ~superseded_memory_id
      (incoming : Keeper_memory_os_types.fact)
  =
  let incoming_identity = memory_id incoming in
  if not (Keeper_memory_os_types.is_memory_id superseded_memory_id)
  then Error Supersede_memory_id_invalid
  else if String.equal incoming_identity superseded_memory_id
  then Error Supersede_self
  else
    update_locked_with_output
      ?clock
      ~declared_revisions:[{superseded=superseded_memory_id; superseded_by=incoming_identity}]
      ~dropped_statements:
        [ { Keeper_memory_os_types.memory_id = superseded_memory_id
          ; reason = "superseded_by " ^ incoming_identity
          }
        ]
      ~equal_facts:(Write_revision None)
      ~store_error:(fun detail -> Supersede_persistence_failed detail)
      ~keepers_dir
      ~keeper_id
      ~now
      (fun ~snapshot_content:_ previous ->
      let current_facts =
        match previous with
        | None -> []
        | Some snapshot -> snapshot.facts
      in
      let* disposition =
        match
          List.find_opt
            (fun fact -> String.equal (memory_id fact) superseded_memory_id)
            current_facts
        with
        | None ->
          (match find_removal ~keepers_dir ~keeper_id superseded_memory_id with
           | Removed removal ->
             (match removal.removed_by.kind, removal.removed_origin with
              | Librarian, Authored -> Ok (Target_already_dropped removal)
              | Librarian, Injected ->
                Error (Supersede_target_not_authored superseded_memory_id)
              | (Explicit_write | Explicit_retract), (Authored | Injected) ->
                Error (Supersede_target_removed removal))
           | No_removal_recorded -> Error (Supersede_target_not_current superseded_memory_id)
           | Journal_unreadable detail -> Error (Supersede_journal_unreadable detail))
        | Some { origin = { kind = Keeper_memory_os_types.Authored; _ }; _ } ->
          Ok Superseded_current
        | Some { origin = { kind = Keeper_memory_os_types.Injected; _ }; _ } ->
          Error (Supersede_target_not_authored superseded_memory_id)
      in
      match disposition with
      | Target_already_dropped _ ->
        upsert_snapshot ~previous ~now ~source incoming
        |> Result.map (fun next -> next, disposition)
        |> Result.map_error (function
          | Unsupported_derivation invalidation -> Supersede_unsupported_derivation invalidation
          | Upsert_persistence_failed detail -> Supersede_persistence_failed detail)
      | Superseded_current ->
      let remaining =
        List.filter
          (fun fact -> not (String.equal (memory_id fact) superseded_memory_id))
          current_facts
      in
      let facts, invalidated =
        maintain_supported_facts (insert_or_reobserve remaining incoming)
      in
      match
        List.find_opt
          (fun invalidation ->
             String.equal (memory_id invalidation.fact) incoming_identity)
          invalidated
      with
      | Some invalidation
        when List.exists
               (String.equal superseded_memory_id)
               invalidation.missing_premise_ids ->
        Error (Supersede_successor_rests_on_target invalidation)
      | Some invalidation -> Error (Supersede_unsupported_derivation invalidation)
      | None ->
        make_snapshot_from_maintained
          ~previous
          ~now
          ~source
          ~facts
          ~invalidated
          ()
        |> Result.map (fun next -> next, disposition)
        |> Result.map_error (fun detail -> Supersede_persistence_failed detail))
    |> Result.map (fun (snapshot, (_ : commit_effect), disposition) -> snapshot, disposition)
;;

let retract_facts
      ?clock
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      ~expected_snapshot_sha256
      ~now
      ~(source : source)
      retractions
  =
  let rec validate index seen = function
    | [] -> Ok seen
    | ({ memory_id; reason } : retraction) :: rest ->
      if not (Keeper_memory_os_types.is_memory_id memory_id)
      then Error (Retract_batch_memory_id_invalid { index })
      else if String.equal (String.trim reason) ""
      then Error (Retract_batch_reason_empty { index })
      else if Set_util.StringSet.mem memory_id seen
      then Error (Retract_batch_duplicate_memory_id memory_id)
      else
        validate
          (index + 1)
          (Set_util.StringSet.add memory_id seen)
          rest
  in
  if not (String_util.is_lowercase_sha256_hex expected_snapshot_sha256)
  then Error Retract_batch_snapshot_sha256_invalid
  else match retractions with
  | [] -> Error Retract_batch_empty
  | _ :: _ ->
    let* target_ids = validate 0 Set_util.StringSet.empty retractions in
    let dropped_statements =
      List.map
        (fun ({ memory_id; reason } : retraction) ->
           { Keeper_memory_os_types.memory_id; reason })
        retractions
    in
    update_locked_with_error
      ?clock
      ~dropped_statements
      ~retraction_plan:
        ( source.trace_id
        , fun ~plan_id ~snapshot_revision ~snapshot_sha256 ~detail ->
            Retract_batch_plan_evidence_pending
              { plan_id; snapshot_revision; snapshot_sha256; detail } )
      ~store_error:(fun detail -> Retract_batch_persistence_failed detail)
      ~keepers_dir
      ~keeper_id
      ~now
      (fun ~snapshot_content previous ->
      let observed_revision =
        Option.map (fun snapshot -> snapshot.revision) previous
      in
      let observed_snapshot_sha256 = Option.map sha256 snapshot_content in
      if
        observed_revision <> Some expected_revision
        || observed_snapshot_sha256 <> Some expected_snapshot_sha256
      then
        Error
          (Retract_batch_snapshot_conflict
             { expected_revision
             ; observed_revision
             ; expected_snapshot_sha256
             ; observed_snapshot_sha256
             })
      else
        let current_facts =
          match previous with
          | None -> []
          | Some snapshot -> snapshot.facts
        in
        let* facts, invalidated =
          retract_current_facts ~target_ids current_facts
          |> Result.map_error (fun missing ->
               Retract_batch_fact_not_found missing)
        in
        make_snapshot_from_maintained
          ~previous
          ~now
          ~source
          ~facts
          ~invalidated
          ()
        |> Result.map_error (fun detail ->
             Retract_batch_persistence_failed detail))
;;

(* Read-side projection of every closed journal shape. *)
let decoded_journal_entry_to_json = function
  | Journal_committed { recorded_at; revision; source; change; dropped } ->
    `Assoc
      ([ "outcome", `String committed_outcome
       ; "recorded_at", `Float recorded_at
       ; "revision", `Int revision
       ; "source", source_to_json source
       ; "change", change_to_json change
       ]
       @
       match dropped with
       | None -> []
       | Some statements ->
         [ "dropped", `List (List.map dropped_statement_to_json statements) ])
  | Journal_failed { recorded_at; trace_id; kind; detail; snapshot_present } ->
    `Assoc
      [ "outcome", `String failed_outcome
      ; "recorded_at", `Float recorded_at
      ; "trace_id", `String trace_id
      ; "kind", `String (librarian_failure_kind_to_string kind)
      ; "detail", `String detail
      ; "snapshot_present", `Bool snapshot_present
      ]
  | Journal_quarantined { recorded_at; rejection; rejected_path } ->
    journal_quarantine_to_json ~now:recorded_at ~rejection ~rejected_path
;;

(* A line this build could not decode keeps its position and says why. Dropping
   it would make a journal with a torn line read as a shorter one, and the
   operator counting passes is the one who would be misled. *)
let journal_line_to_json = function
  | Ok entry ->
    (match decoded_journal_entry_to_json entry with
     | `Assoc fields -> `Assoc (("ok", `Bool true) :: fields)
     | json -> json)
  | Error reason -> `Assoc [ "ok", `Bool false; "error", `String reason ]
;;

let journal_projection_identity ~keeper_id line_offset =
  Printf.sprintf "memory:journal:%d:%s:%d" (String.length keeper_id) keeper_id
    line_offset
;;

let read_journal_tail_projection ~keepers_dir ~keeper_id ~limit =
  read_journal_tail_indexed ~keepers_dir ~keeper_id ~limit
  |> List.map (fun (line_offset, result) ->
       match journal_line_to_json result with
       | `Assoc fields ->
         `Assoc
           (( "structural_id"
            , `String (journal_projection_identity ~keeper_id line_offset) )
            :: fields)
       | json -> json)
;;

(* Boot-time twin of the writer's quarantine above: the same decoder, the
   same locks, the same move-aside and journal line, but run once over every
   keeper before any keeper loop starts. A snapshot this build cannot decode
   is therefore never discovered mid-turn by whichever read or write happens
   to come first. *)
let move_aside_for_keepers_dir ?clock ~keepers_dir ~keeper_id ~now ~rejection () =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  Keeper_memory_os_aggregate_lock.with_lock ?clock ~keepers_dir ~keeper_id (fun () ->
    File_lock_eio.with_lock ?clock snapshot_path (fun () ->
      quarantine_snapshot_and_receipt
        ~keepers_dir ~keeper_id ~snapshot_path ~now ~rejection))
;;

module For_testing = struct
  let durable_range_receipt_decodes () = Atomic.get durable_range_receipt_decodes
end
