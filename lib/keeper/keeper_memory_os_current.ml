(** Keeper-owned current Memory OS snapshot. *)

open Keeper_memory_os_types
open Result.Syntax

let schema = "keeper.memory.current.v1"
let suffix = ".memory.json"
let keepers_dir_override : string option ref = ref None

let keepers_dir () =
  match !keepers_dir_override with
  | Some path -> path
  | None -> Config_dir_resolver.keepers_dir ()
;;

module For_testing = struct
  let with_keepers_dir path f =
    Fs_compat.mkdir_p path;
    let previous = !keepers_dir_override in
    keepers_dir_override := Some path;
    Fun.protect
      ~finally:(fun () -> keepers_dir_override := previous)
      f
  ;;
end

type source_kind =
  | Librarian
  | Explicit_write

type source =
  { kind : source_kind
  ; trace_id : string
  ; generation : int
  }

type change =
  { added : fact list
  ; removed : fact list
  ; retained : int
  }

type t =
  { revision : int
  ; updated_at : float
  ; source : source
  ; summary : string
  ; facts : fact list
  ; open_items : string list
  ; constraints : string list
  ; preserved_tool_refs : string list
  ; change : change
  }

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

let path ~keeper_id =
  path_for_keepers_dir
    ~keepers_dir:(keepers_dir ())
    ~keeper_id
;;

let list_keeper_ids_for_keepers_dir ~keepers_dir =
  if not (Sys.file_exists keepers_dir && Sys.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map (Filename.chop_suffix_opt ~suffix)
    |> List.sort String.compare
;;

let list_keeper_ids () =
  list_keeper_ids_for_keepers_dir
    ~keepers_dir:(keepers_dir ())
;;

let source_kind_to_string = function
  | Librarian -> "librarian"
  | Explicit_write -> "explicit_write"
;;

let source_kind_of_string = function
  | "librarian" -> Some Librarian
  | "explicit_write" -> Some Explicit_write
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
    [ "kind", `String (source_kind_to_string source.kind)
    ; "trace_id", `String source.trace_id
    ; "generation", `Int source.generation
    ]
;;

let source_of_json = function
  | `Assoc fields
    when exact_object_fields [ "kind"; "trace_id"; "generation" ] fields ->
    (match
       List.assoc_opt "kind" fields
       , List.assoc_opt "trace_id" fields
       , List.assoc_opt "generation" fields
     with
     | Some (`String kind), Some (`String trace_id), Some (`Int generation) ->
       (match source_kind_of_string kind with
        | Some kind
          when not (String.equal (String.trim trace_id) "") && generation >= 0 ->
          Some { kind; trace_id; generation }
        | Some _ | None -> None)
     | _ -> None)
  | _ -> None
;;

let string_list_of_json = function
  | `List values ->
    let rec loop acc = function
      | [] -> Some (List.rev acc)
      | `String value :: rest ->
        let value = String.trim value in
        if String.equal value "" then None else loop (value :: acc) rest
      | _ :: _ -> None
    in
    loop [] values
  | _ -> None
;;

let facts_of_json = function
  | `List values ->
    let rec loop acc = function
      | [] -> Some (List.rev acc)
      | value :: rest ->
        (match fact_of_json value with
         | Some fact -> loop (fact :: acc) rest
         | None -> None)
    in
    loop [] values
  | _ -> None
;;

let facts_to_json facts =
  `List (List.map fact_to_json facts)
;;

let change_to_json change =
  `Assoc
    [ "added", facts_to_json change.added
    ; "removed", facts_to_json change.removed
    ; "retained", `Int change.retained
    ]
;;

let change_of_json = function
  | `Assoc fields
    when exact_object_fields [ "added"; "removed"; "retained" ] fields ->
    (match
       List.assoc_opt "added" fields
       , List.assoc_opt "removed" fields
       , List.assoc_opt "retained" fields
     with
     | Some added, Some removed, Some (`Int retained) ->
       (match facts_of_json added, facts_of_json removed with
        | Some added, Some removed when retained >= 0 ->
          Some { added; removed; retained }
        | (Some _, Some _) | (Some _, None) | (None, _) -> None)
     | _ -> None)
  | _ -> None
;;

let to_json snapshot =
  `Assoc
    [ "schema", `String schema
    ; "revision", `Int snapshot.revision
    ; "updated_at", `Float snapshot.updated_at
    ; "source", source_to_json snapshot.source
    ; "summary", `String snapshot.summary
    ; "facts", facts_to_json snapshot.facts
    ; "open_items", `List (List.map (fun value -> `String value) snapshot.open_items)
    ; "constraints", `List (List.map (fun value -> `String value) snapshot.constraints)
    ; ( "preserved_tool_refs"
      , `List (List.map (fun value -> `String value) snapshot.preserved_tool_refs) )
    ; "change", change_to_json snapshot.change
    ]
;;

let of_json = function
  | `Assoc fields
    when exact_object_fields
           [ "schema"
           ; "revision"
           ; "updated_at"
           ; "source"
           ; "summary"
           ; "facts"
           ; "open_items"
           ; "constraints"
           ; "preserved_tool_refs"
           ; "change"
           ]
           fields ->
    (match
       List.assoc_opt "schema" fields
       , List.assoc_opt "revision" fields
       , List.assoc_opt "updated_at" fields
       , List.assoc_opt "source" fields
       , List.assoc_opt "summary" fields
       , List.assoc_opt "facts" fields
       , List.assoc_opt "open_items" fields
       , List.assoc_opt "constraints" fields
       , List.assoc_opt "preserved_tool_refs" fields
       , List.assoc_opt "change" fields
     with
     | ( Some (`String observed_schema)
       , Some (`Int revision)
       , Some updated_at_json
       , Some source_json
       , Some (`String summary)
       , Some facts_json
       , Some open_items_json
       , Some constraints_json
       , Some preserved_tool_refs_json
       , Some change_json ) ->
       let updated_at =
         match updated_at_json with
         | `Float value -> Some value
         | `Int value -> Some (float_of_int value)
         | _ -> None
       in
       (match
          updated_at
          , source_of_json source_json
          , facts_of_json facts_json
          , string_list_of_json open_items_json
          , string_list_of_json constraints_json
          , string_list_of_json preserved_tool_refs_json
          , change_of_json change_json
        with
        | ( Some updated_at
          , Some source
          , Some facts
          , Some open_items
          , Some constraints
          , Some preserved_tool_refs
          , Some change )
          when String.equal observed_schema schema
               && revision >= 1
               && Float.is_finite updated_at
               && updated_at >= 0.0 ->
          Some
            { revision
            ; updated_at
            ; source
            ; summary
            ; facts
            ; open_items
            ; constraints
            ; preserved_tool_refs
            ; change
            }
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let parse path content =
  try
    match of_json (Yojson.Safe.from_string content) with
    | Some snapshot -> Ok snapshot
    | None -> Error (Printf.sprintf "%s: invalid current Memory OS snapshot" path)
  with
  | Yojson.Json_error message ->
    Error (Printf.sprintf "%s: invalid JSON: %s" path message)
;;

let read_for_keepers_dir ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt snapshot_path with
  | None -> Ok None
  | Some content ->
    let+ snapshot = parse snapshot_path content in
    Some snapshot
;;

let read ~keeper_id =
  read_for_keepers_dir
    ~keepers_dir:(keepers_dir ())
    ~keeper_id
;;

module Identity_map = Map.Make (String)

let fact_payload fact =
  fact_to_json fact |> Yojson.Safe.to_string
;;

let map_facts facts =
  let rec loop map = function
    | [] -> Ok map
    | fact :: rest ->
      let identity = claim_identity fact in
      if Identity_map.mem identity map
      then Error (Printf.sprintf "duplicate Memory OS fact identity: %s" identity)
      else loop (Identity_map.add identity fact map) rest
  in
  loop Identity_map.empty facts
;;

let compute_change ~previous ~next =
  let* previous_by_id = map_facts previous in
  let* next_by_id = map_facts next in
  let added, retained =
    Identity_map.fold
      (fun identity next_fact (added, retained) ->
         match Identity_map.find_opt identity previous_by_id with
         | Some previous_fact
           when String.equal (fact_payload previous_fact) (fact_payload next_fact) ->
           added, retained + 1
         | Some _ | None -> next_fact :: added, retained)
      next_by_id
      ([], 0)
  in
  let removed =
    Identity_map.fold
      (fun identity previous_fact removed ->
         match Identity_map.find_opt identity next_by_id with
         | Some next_fact
           when String.equal (fact_payload previous_fact) (fact_payload next_fact) ->
           removed
         | Some _ | None -> previous_fact :: removed)
      previous_by_id
      []
  in
  Ok
    { added = List.rev added
    ; removed = List.rev removed
    ; retained
    }
;;

let lock_path snapshot_path = snapshot_path ^ ".lock"

let update_locked
      ?clock
      ~keeper_id
      build
  =
  let snapshot_path = path ~keeper_id in
  File_lock_eio.with_lock ?clock (lock_path snapshot_path) (fun () ->
    let* previous =
      match Fs_compat.load_file_opt snapshot_path with
      | None -> Ok None
      | Some content ->
        let+ snapshot = parse snapshot_path content in
        Some snapshot
    in
    let* next = build previous in
    let content = Yojson.Safe.pretty_to_string (to_json next) ^ "\n" in
    match Fs_compat.save_file_atomic snapshot_path content with
    | Ok () -> Ok next
    | Error message ->
      Error
        (Printf.sprintf
           "current Memory OS atomic write failed path=%s: %s"
           snapshot_path
           message))
;;

let make_snapshot
      ~previous
      ~now
      ~source
      ~summary
      ~facts
      ~open_items
      ~constraints
      ~preserved_tool_refs
      ()
  =
  let previous_facts, revision =
    match previous with
    | None -> [], 1
    | Some snapshot -> snapshot.facts, snapshot.revision + 1
  in
  let+ change = compute_change ~previous:previous_facts ~next:facts in
  { revision
  ; updated_at = now
  ; source
  ; summary
  ; facts
  ; open_items
  ; constraints
  ; preserved_tool_refs
  ; change
  }
;;

let replace
      ?clock
      ~keeper_id
      ~now
      ~source
      ~summary
      ~facts
      ~open_items
      ~constraints
      ~preserved_tool_refs
      ()
  =
  update_locked ?clock ~keeper_id (fun previous ->
    make_snapshot
      ~previous
      ~now
      ~source
      ~summary
      ~facts
      ~open_items
      ~constraints
      ~preserved_tool_refs
      ())
;;

let upsert_fact
      ?clock
      ~keeper_id
      ~now
      ~source
      incoming
  =
  update_locked ?clock ~keeper_id (fun previous ->
    let current_facts, summary, open_items, constraints, preserved_tool_refs =
      match previous with
      | None -> [], "Explicit keeper memory write.", [], [], []
      | Some snapshot ->
        ( snapshot.facts
        , snapshot.summary
        , snapshot.open_items
        , snapshot.constraints
        , snapshot.preserved_tool_refs )
    in
    let incoming_identity = claim_identity incoming in
    let found = ref false in
    let facts =
      List.map
        (fun existing ->
           if String.equal (claim_identity existing) incoming_identity
           then (
             found := true;
             incoming)
           else existing)
        current_facts
    in
    let facts = if !found then facts else facts @ [ incoming ] in
    make_snapshot
      ~previous
      ~now
      ~source
      ~summary
      ~facts
      ~open_items
      ~constraints
      ~preserved_tool_refs
      ())
;;
