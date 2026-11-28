module Types = Keeper_memory_os_types

type t =
  { inserted : int
  ; retracted : int
  ; removed_otherwise : int
  ; last_retracted_at : float option
  ; unreadable : int
  ; folded : bool
  }

let empty ~unreadable ~folded =
  { inserted = 0
  ; retracted = 0
  ; removed_otherwise = 0
  ; last_retracted_at = None
  ; unreadable
  ; folded
  }
;;

let count_removal ~at acc (removal : Librarian_effects.removal) =
  match removal with
  | Retracted _ ->
    let last_retracted_at =
      match acc.last_retracted_at with
      | Some previous when previous >= at -> Some previous
      | Some _ | None -> Some at
    in
    { acc with retracted = acc.retracted + 1; last_retracted_at }
  | Dropped _ | Merged_into _ | Revised_into _ | Superseded_by _ | Support_lost _ | Molted _ ->
    { acc with removed_otherwise = acc.removed_otherwise + 1 }
;;

let is_id ~memory_id fact = String.equal (Types.memory_id fact) memory_id

let of_history ~memory_id (history : Librarian_archive.history) =
  let initial =
    empty ~unreadable:history.unreadable ~folded:(Option.is_some history.folded)
  in
  let after_unsequenced =
    List.fold_left
      (fun acc (left : Librarian_archive.left) ->
         if is_id ~memory_id left.fact then count_removal ~at:left.at acc left.removal else acc)
      initial
      history.unsequenced
  in
  List.fold_left
    (fun acc (change : Librarian_memory_change.t) ->
       let acc =
         if List.exists (is_id ~memory_id) change.added
         then { acc with inserted = acc.inserted + 1 }
         else acc
       in
       List.fold_left
         (fun acc (fact, removal) ->
            if is_id ~memory_id fact then count_removal ~at:change.at acc removal else acc)
         acc
         change.removed)
    after_unsequenced
    history.changes
;;

let read ~keepers_dir ~keeper_id ~memory_id =
  let path = Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id in
  (* The same scan [keeper_memory_search] runs for removed facts, off the
     calling fiber's domain like that one. *)
  match
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Librarian_archive.history path)
  with
  | Ok history -> Ok (of_history ~memory_id history)
  | Error error -> Error (Private_jsonl_scan.error_to_string error)
;;

let to_json t =
  `Assoc
    ([ "inserted", `Int t.inserted
     ; "retracted", `Int t.retracted
     ; "removed_otherwise", `Int t.removed_otherwise
     ; ( "last_retracted_at"
       , match t.last_retracted_at with
         | Some at -> `String (Masc_domain.iso8601_of_unix_seconds at)
         | None -> `Null )
     ]
     @ (if t.unreadable = 0 then [] else [ "unreadable_log_lines", `Int t.unreadable ])
     @ if t.folded then [ "older_inserts_folded", `Bool true ] else [])
;;

let receipt_field = function
  | Ok t -> "memory_id_history", to_json t
  | Error detail -> "memory_id_history_unavailable", `String detail
;;
