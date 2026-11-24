module Types = Keeper_memory_os_types
module Log = Librarian_log
module Log_store = Librarian_log_store
module Codec = Librarian_log_codec
module By_id = Map.Make (String)
module By_seq = Map.Make (Int)
module Seqs = Set.Make (Int)
module Change = Librarian_memory_change

type left =
  { fact : Types.fact
  ; removal : Librarian_effects.removal
  ; at : float
  ; line_at : int
  }

type t =
  { left : left list
  ; unreadable : int
  }

let max_detailed_rows = 2000

type folded =
  { through_seq : int; min_revision : int; max_revision : int; min_at : float; max_at : float }

type damage_origin = Live_log | Cold_archive | Cold_fragment

let damage_origin_to_string = function
  | Live_log -> "live"
  | Cold_archive -> "archive"
  | Cold_fragment -> "archive_fragment"

let damage_origin_of_string = function
  | "live" -> Some Live_log
  | "archive" -> Some Cold_archive
  | "archive_fragment" -> Some Cold_fragment
  | _ -> None

type damage = { origin : damage_origin; after_seq : int; encoded : string }

module Opaque_rows = Set.Make (struct
  type t = damage
  let compare a b = String.compare a.encoded b.encoded
end)

type live_damage = { rows : int; max_after_seq : int }

type coverage =
  { detail_rows : int
  ; unsequenced_rows : int
  ; unsequenced_time : (float * float) option
  ; unreadable_rows : int
  ; live_damage : live_damage option
  ; conflicting_sequences : int
  ; last_seq : int
  ; folded_detail : folded option
  }

let combine_folded a b =
  { through_seq = max a.through_seq b.through_seq;
    min_revision = min a.min_revision b.min_revision; max_revision = max a.max_revision b.max_revision;
    min_at = min a.min_at b.min_at; max_at = max a.max_at b.max_at }

let add_folded prior value = Some (Option.fold ~none:value ~some:(combine_folded value) prior)

let folded_json f =
  `List [`String "librarian.folded.v1"; `Int f.through_seq; `Int f.min_revision;
         `Int f.max_revision; `Float f.min_at; `Float f.max_at]

let folded_of_json = function
  | `List [`String "librarian.folded.v1"; `Int through_seq; `Int min_revision;
           `Int max_revision; `Float min_at; `Float max_at]
    when through_seq > 0 && min_revision >= 0 && min_revision <= max_revision
         && Float.is_finite min_at && Float.is_finite max_at && min_at <= max_at ->
    Some { through_seq; min_revision; max_revision; min_at; max_at }
  | _ -> None

let time_range_of_json = function
  | `List [`Float lo; `Float hi] when Float.is_finite lo && Float.is_finite hi && lo <= hi ->
    Some (lo, hi)
  | _ -> None

let live_damage_of_json = function
  | `List [`Int rows; `Int max_after_seq] when rows > 0 && max_after_seq >= 0 ->
    Some { rows; max_after_seq }
  | _ -> None

let decode_optional decode = function
  | `Null -> Some None
  | json -> Option.map (fun value -> Some value) (decode json)

let coverage_json c =
  let unsequenced_time = Option.fold ~none:`Null
      ~some:(fun (lo, hi) -> `List [`Float lo; `Float hi]) c.unsequenced_time in
  let live_damage = Option.fold ~none:`Null
      ~some:(fun s -> `List [`Int s.rows; `Int s.max_after_seq]) c.live_damage in
  `List [`String "librarian.coverage.v1"; `Int c.detail_rows; `Int c.unsequenced_rows;
         unsequenced_time; `Int c.unreadable_rows; live_damage; `Int c.conflicting_sequences; `Int c.last_seq;
         Option.fold ~none:`Null ~some:folded_json c.folded_detail]

type retained = { opaque : Opaque_rows.t; conflicts : Change.t list }

type history =
  { unsequenced : left list
  ; changes : Change.t list
  ; unreadable : int
  ; live_lines : int
  ; folded : folded option
  ; retained : retained
  }

type seen =
  { gone : (int * left) By_id.t
  ; removals : int
  }

let left_to_json (entry : left) =
  `Assoc
    [ "fact", Types.fact_to_json entry.fact
    ; "removal", Codec.removal_to_json entry.removal
    ; "at", `Float entry.at
    ; "line_at", `Int entry.line_at
    ]
;;

let left_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () = Types.exact_field_names_result [ "fact"; "removal"; "at"; "line_at" ] fields in
    let* fact_json = Types.wire_json_field "fact" fields in
    let* fact = Types.wire_at (Types.Wire_field "fact") (Types.fact_of_json fact_json) in
    let* removal_json = Types.wire_json_field "removal" fields in
    let* removal =
      Types.wire_at (Types.Wire_field "removal") (Codec.removal_of_json removal_json)
    in
    let* at = Types.wire_number_field "at" fields in
    let* line_at = Types.wire_int_field "line_at" fields in
    if Float.is_finite at then Ok { fact; removal; at; line_at }
    else Types.wire_fail [ Types.Wire_field "at" ] Types.Not_finite
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Types.wire_here Types.Expected_object
;;

type cold_row =
  | Left of left
  | Detail of Change.t
  | Folded of folded
  | Coverage of coverage
  | Opaque of damage
  | Invalid

let cold_row raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error _ -> Invalid
  | `List (`String "librarian.folded.v1" :: _) as json ->
    (match folded_of_json json with Some f -> Folded f | None -> Invalid)
  | `List [`String "librarian.coverage.v1"; `Int detail_rows; `Int unsequenced_rows;
           time; `Int unreadable_rows; damage; `Int conflicting_sequences; `Int last_seq; folded]
    when detail_rows >= 0 && detail_rows <= max_detailed_rows && unsequenced_rows >= 0
         && unreadable_rows >= 0 && conflicting_sequences >= 0 && conflicting_sequences <= last_seq
         && detail_rows <= last_seq - conflicting_sequences ->
    (match decode_optional time_range_of_json time,
           decode_optional live_damage_of_json damage, decode_optional folded_of_json folded with
     | Some unsequenced_time, Some live_damage, Some folded_detail
       when Bool.equal (unsequenced_rows = 0) (Option.is_none unsequenced_time)
            && Option.fold ~none:true ~some:(fun s -> s.rows <= unreadable_rows) live_damage
            && Option.fold ~none:true ~some:(fun f -> f.through_seq <= last_seq
                 && detail_rows <= last_seq - f.through_seq) folded_detail ->
       Coverage { detail_rows; unsequenced_rows; unsequenced_time; unreadable_rows; live_damage;
                  conflicting_sequences; last_seq; folded_detail }
     | _ -> Invalid)
  | `List [`String "librarian.unreadable.v1"; `String origin; `Int offset;
           `Int after_seq; `String bytes] as marker
    when offset >= 0 && after_seq >= 0 && Result.is_ok (Base64.decode bytes) ->
    (match damage_origin_of_string origin with
     | Some origin -> Opaque { origin; after_seq; encoded = Yojson.Safe.to_string marker }
     | None -> Invalid)
  | `Assoc fields as json when List.mem_assoc "seq" fields ->
    (match Change.of_json json with Ok c -> Detail c | Error _ -> Invalid)
  | json -> (match left_of_json json with Ok left -> Left left | Error _ -> Invalid)

let record_left seen (entry : left) =
  { gone = By_id.add (Types.memory_id entry.fact) (seen.removals, entry) seen.gone
  ; removals = seen.removals + 1
  }
;;

let after_change seen (c : Change.t) =
  let seen = List.fold_left
      (fun seen (fact, removal) -> record_left seen { fact; removal; at = c.at; line_at = c.line_at })
      seen c.removed in
  { seen with gone = List.fold_left (fun gone fact -> By_id.remove (Types.memory_id fact) gone)
                       seen.gone c.added }
;;

let left_of_history (history : history) ~current =
  let initial = { gone = By_id.empty; removals = 0 } in
  let seen = List.fold_left record_left initial history.unsequenced in
  let seen = List.fold_left after_change seen history.changes in
  let gone = List.fold_left (fun gone fact -> By_id.remove (Types.memory_id fact) gone) seen.gone current in
  let ordered = By_id.bindings gone |> List.map snd |> List.sort (fun (a, _) (b, _) -> Int.compare a b) in
  { left = List.map snd ordered; unreadable = history.unreadable }
;;

let compact_details (history : history) =
  let excess = List.length history.changes - max_detailed_rows in
  if excess <= 0 then history else
    let old = List.take excess history.changes and changes = List.drop excess history.changes in
    let unsequenced = (left_of_history { history with changes = old } ~current:[]).left in
    let folded = List.fold_left (fun prior (c : Change.t) -> add_folded prior
      { through_seq = c.seq; min_revision = c.revision; max_revision = c.revision;
        min_at = c.at; max_at = c.at }) history.folded old in
    { history with unsequenced; changes; folded }

let coverage_of_history (history : history) =
  let unsequenced_time = List.fold_left (fun range (e : left) ->
      Some (match range with None -> e.at, e.at | Some (lo, hi) -> min lo e.at, max hi e.at))
      None history.unsequenced in
  let conflict_seqs = List.fold_left (fun seqs (c : Change.t) -> Seqs.add c.seq seqs)
      Seqs.empty history.retained.conflicts in
  let last_seq = Option.fold ~none:0 ~some:(fun f -> f.through_seq) history.folded in
  let last_seq = max last_seq (Option.value ~default:0 (Seqs.max_elt_opt conflict_seqs)) in
  let last_seq = List.fold_left (fun n (c : Change.t) -> max n c.seq) last_seq history.changes in
  let live_damage = Opaque_rows.fold (fun damage prior ->
      match damage.origin with
      | Cold_archive | Cold_fragment -> prior
      | Live_log -> Some (match prior with
        | None -> { rows = 1; max_after_seq = damage.after_seq }
        | Some prior -> { rows = prior.rows + 1; max_after_seq = max prior.max_after_seq damage.after_seq }))
      history.retained.opaque None in
  { detail_rows = List.length history.changes; unsequenced_rows = List.length history.unsequenced;
    unsequenced_time; unreadable_rows = Opaque_rows.cardinal history.retained.opaque; live_damage;
    conflicting_sequences = Seqs.cardinal conflict_seqs; last_seq; folded_detail = history.folded }

let write_history ~archive_path (history : history) =
  let dir = Filename.dirname archive_path in
  match Fs_compat.mkdir_p dir with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Printexc.to_string exn)
  | () ->
    let buf = Buffer.create 4096 in
    let write json = Buffer.add_string buf (Yojson.Safe.to_string json); Buffer.add_char buf '\n' in
    let history = compact_details history in
    List.iter (fun c -> write (Change.to_json c)) history.retained.conflicts;
    Opaque_rows.iter (fun damage -> Buffer.add_string buf damage.encoded; Buffer.add_char buf '\n') history.retained.opaque;
    List.iter (fun old -> write (left_to_json old)) history.unsequenced;
    List.iter (fun c -> write (Change.to_json c)) history.changes;
    write (coverage_json (coverage_of_history history));
    Fs_compat.save_file_atomic_strict archive_path (Buffer.contents buf)
;;

type lock_entry =
  { mu : Cross_context_mutex.t
  ; mutable users : int
  }

let lock_registry_mu = Mutex.create ()
let path_locks : (string, lock_entry) Hashtbl.t = Hashtbl.create 16

let canonical_lock_key log_path =
  let dir = Filename.dirname log_path in
  let base = Filename.basename log_path in
  let real_dir =
    try Unix.realpath dir with
    | Unix.Unix_error _ -> dir
  in
  Filename.concat real_dir base
;;

let with_path_lock ~log_path f =
  let key = canonical_lock_key log_path in
  let entry =
    Mutex.lock lock_registry_mu;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock lock_registry_mu)
      (fun () ->
         match Hashtbl.find_opt path_locks key with
         | Some e ->
           e.users <- e.users + 1;
           e
         | None ->
           let e = { mu = Cross_context_mutex.create (); users = 1 } in
           Hashtbl.replace path_locks key e;
           e)
  in
  let release () =
    Mutex.lock lock_registry_mu;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock lock_registry_mu)
      (fun () ->
         entry.users <- entry.users - 1;
         if entry.users <= 0 then Hashtbl.remove path_locks key)
  in
  Fun.protect ~finally:release (fun () -> Cross_context_mutex.with_lock entry.mu f)
;;

let damaged_row ~origin ~at ~after_seq raw =
  let encoded = Yojson.Safe.to_string (`List [`String "librarian.unreadable.v1";
    `String (damage_origin_to_string origin); `Int at; `Int after_seq; `String (Base64.encode_string raw)]) in
  { origin; after_seq; encoded }
let remember_raw ~origin ~at ~after_seq raw opaque =
  Opaque_rows.add (damaged_row ~origin ~at ~after_seq raw) opaque

let history_unlocked path =
  let open Result.Syntax in
  (* A checkpoint publishes the archive first. Capturing live before cold
     therefore sees either copy of every committed sequence, including when
     another process is between the two atomic renames. *)
  let* live, live_opaque, live_lines, _ =
    Log_store.fold_with_raw path ~init:([], Opaque_rows.empty, 0, 0)
      ~f:(fun (changes, opaque, count, after_seq) row raw ->
        match row.Log_store.line with
        | Ok (Log.Started _) -> changes, opaque, count + 1, after_seq
        | Ok (Committed commit) ->
          Change.of_commit ~line_at:row.at commit :: changes, opaque, count + 1, commit.seq
        | Error _ ->
          changes, remember_raw ~origin:Live_log ~at:row.at ~after_seq raw opaque, count + 1, after_seq)
  in
  let cold = Log_store.archive_path_of_log_path path in
  let add_change events (c : Change.t) =
    By_seq.update c.seq (function
      | None -> Some [c]
      | Some copies when List.exists (Change.same_event c) copies -> Some copies
      | Some copies -> Some (c :: copies)) events in
  let* old, versions, opaque, complete_end, after_seq, folded =
    Private_jsonl_scan.fold cold ~rows_per_read:128 ~init:([], By_seq.empty, live_opaque, 0, 0, None)
      ~f:(fun (old, versions, opaque, _, after_seq, folded) ~at raw ->
        let next = at + String.length raw + 1 in
        match cold_row raw with
        | Invalid -> old, versions, remember_raw ~origin:Cold_archive ~at ~after_seq raw opaque, next, after_seq, folded
        | Opaque marker -> old, versions, Opaque_rows.add marker opaque, next, after_seq, folded
        | Detail c -> old, add_change versions c, opaque, next, max after_seq c.seq, folded
        | Left left -> left :: old, versions, opaque, next, after_seq, folded
        | Folded boundary -> old, versions, opaque, next, after_seq, add_folded folded boundary
        | Coverage { folded_detail; _ } ->
          let folded = Option.fold ~none:folded ~some:(add_folded folded) folded_detail in
          old, versions, opaque, next, after_seq, folded)
  in
  (* A fragment in the atomically published archive is evidence of damage.
     Keep its exact bytes opaque even when those bytes alone parse as JSON. *)
  let* opaque =
    match Fs_compat.read_private_jsonl_tail_locked_result cold ~max_bytes:1 with
    | Fs_compat.Private_file_failed err
    | Private_file_failed_with_cleanup_failure { error = err; _ } ->
      Error (Private_jsonl_scan.Read_failed { path = cold; detail = Fs_compat.Private_jsonl_tail.error_to_string err })
    | Private_file_succeeded tail | Private_file_succeeded_with_cleanup_failure { value = tail; _ } ->
      (match tail with
       | Fs_compat.Private_jsonl_tail.Tail_present { incomplete_tail = true; end_offset; _ }
         when end_offset > complete_end ->
         let length = end_offset - complete_end in
         (match Fs_compat.load_owned_regular_file_range ~ownership_root:(Filename.dirname cold)
                  ~offset:complete_end ~max_bytes:length cold with
          | Ok (Some row) when row.snapshot.file_size = end_offset && String.length row.content = length
                               && not (String.contains row.content '\n') ->
            Ok (remember_raw ~origin:Cold_fragment ~at:complete_end ~after_seq row.content opaque)
          | Ok _ -> Error Private_jsonl_scan.Moved
          | Error e -> Error (Private_jsonl_scan.Read_failed
              { path = cold; detail = Fs_compat.owned_regular_file_read_error_to_string e }))
       | Tail_missing when complete_end = 0 -> Ok opaque
       | Tail_present { incomplete_tail = false; end_offset; _ } when end_offset = complete_end -> Ok opaque
       | Tail_missing | Tail_present _ -> Error Private_jsonl_scan.Moved)
  in
  let versions = List.fold_left add_change versions live in
  let changes, conflicts, unreadable = By_seq.fold (fun _ copies (changes, conflicts, n) ->
    match copies with
    | [one] when Option.fold ~none:false ~some:(fun f -> one.Change.seq <= f.through_seq) folded ->
      changes, conflicts, n
    | [one] -> one :: changes, conflicts, n
    | many -> changes, List.rev_append many conflicts, n + 1)
    versions ([], [], Opaque_rows.cardinal opaque) in
  let changes = List.rev changes in
  (* A pre-change writer could have published the old removal sidecar while
     the corresponding live log was still visible. Only suppress an exact
     removal occurrence. Repeated changes to a fact at other times survive. *)
  let known = Hashtbl.create 16 in
  List.iter (fun (c : Change.t) ->
    List.iter (fun (fact, removal) -> Hashtbl.replace known (Types.memory_id fact, removal, c.at) ())
      c.removed) changes;
  let unsequenced = List.rev old |> List.filter (fun (e : left) ->
    not (Hashtbl.mem known (Types.memory_id e.fact, e.removal, e.at))) in
  Ok { unsequenced; changes; unreadable; live_lines; folded; retained = { opaque; conflicts } }
;;

let history path = with_path_lock ~log_path:path (fun () -> history_unlocked path)

let read path ~current =
  Result.map (fun history -> left_of_history history ~current) (history path)
;;
