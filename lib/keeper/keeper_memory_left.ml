module Types = Keeper_memory_os_types
module StringSet = Set_util.StringSet
module StringMap = Set_util.StringMap

type how =
  | Merged
  | Revised
  | Superseded

type absorbed =
  { left : Librarian_archive.left
  ; how : how
  ; into : string
  ; into_current : bool
  }

type why =
  | Dropped of { reason : string }
  | Retracted of
      { by : Librarian_effects.actor
      ; reason : string
      }
  | Support_lost of { missing : string list }

type dropped =
  { left : Librarian_archive.left
  ; why : why
  }

type t =
  { absorbed : absorbed list
  ; dropped : dropped list
  ; unreadable : int
  }

(* Every removal is one of the two: another fact took the place, or none did. *)
type sorted =
  | Taken of how * string
  | Ended of why

let sort_removal : Librarian_effects.removal -> sorted = function
  | Merged_into into -> Taken (Merged, into)
  | Revised_into into -> Taken (Revised, into)
  | Superseded_by into -> Taken (Superseded, into)
  | Dropped { reason } -> Ended (Dropped { reason })
  | Retracted { by; reason } -> Ended (Retracted { by; reason })
  | Support_lost { missing } -> Ended (Support_lost { missing })
;;

(* [named] maps a fact that left for another fact to that fact's id. *)
let rec walk ~current ~named ~passed id =
  if StringSet.mem id current
  then id
  else (
    match StringMap.find_opt id named with
    | None -> id
    | Some next when StringSet.mem next passed -> id
    | Some next -> walk ~current ~named ~passed:(StringSet.add id passed) next)
;;

let read ~keepers_dir ~keeper_id ~current =
  let path = Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Librarian_archive.read path ~current with
  | Error error -> Error (Private_jsonl_scan.error_to_string error)
  | Ok { left; unreadable } ->
    let sorted =
      List.map (fun (entry : Librarian_archive.left) -> entry, sort_removal entry.removal) left
    in
    let named =
      List.fold_left
        (fun named ((entry : Librarian_archive.left), sorted) ->
           match sorted with
           | Taken (_, into) -> StringMap.add (Types.memory_id entry.fact) into named
           | Ended _ -> named)
        StringMap.empty
        sorted
    in
    let current_ids =
      List.fold_left
        (fun ids fact -> StringSet.add (Types.memory_id fact) ids)
        StringSet.empty
        current
    in
    let absorbed, dropped =
      List.partition_map
        (fun ((entry : Librarian_archive.left), sorted) ->
           match sorted with
           | Taken (how, named_into) ->
             let into =
               walk
                 ~current:current_ids
                 ~named
                 ~passed:(StringSet.singleton (Types.memory_id entry.fact))
                 named_into
             in
             Either.Left
               { left = entry; how; into; into_current = StringSet.mem into current_ids }
           | Ended why -> Either.Right { left = entry; why })
        sorted
    in
    Ok { absorbed; dropped; unreadable }
;;

let how_to_string = function
  | Merged -> "merged"
  | Revised -> "revised"
  | Superseded -> "superseded"
;;

let fact_fields (left : Librarian_archive.left) =
  let fact = left.fact in
  [ "text", `String fact.Types.claim
  ; "memory_id", `String (Types.memory_id fact)
  ; "category", `String (Types.category_to_string fact.Types.category)
  ; "basis", Types.basis_to_json fact.Types.basis
  ]
;;

let left_at (left : Librarian_archive.left) =
  `String (Masc_domain.iso8601_of_unix_seconds left.at)
;;

let absorbed_to_json ({ left; how; into; into_current } : absorbed) =
  `Assoc
    (fact_fields left
     @ [ "store", `String "absorbed_memory"
       ; "how", `String (how_to_string how)
       ; "into", `String into
       ; "into_current", `Bool into_current
       ; "absorbed_at", left_at left
       ])
;;

let removed_by : Librarian_effects.actor -> string = function
  | Keeper -> "keeper"
  | Operator (_ : string) -> "operator"
;;

let why_fields = function
  | Dropped { reason } ->
    [ "removal", `String "dropped"; "removed_by", `String "librarian"; "reason", `String reason ]
  | Retracted { by; reason } ->
    [ "removal", `String "retracted"
    ; "removed_by", `String (removed_by by)
    ; "reason", `String reason
    ]
  | Support_lost { missing } ->
    [ "removal", `String "support_lost"
    ; "missing_premises", `List (List.map (fun id -> `String id) missing)
    ]
;;

let dropped_to_json ({ left; why } : dropped) =
  `Assoc
    (fact_fields left
     @ [ "store", `String "dropped_memory"; "current", `Bool false; "removed_at", left_at left ]
     @ why_fields why)
;;
