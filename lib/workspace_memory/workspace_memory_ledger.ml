type fact_ref =
  | Ordinary of
      { keeper_id : string
      ; claim_sha256 : string
      }
  | Source_bound of
      { keeper_id : string
      ; path : string
      ; claim_sha256 : string
      }

type disposition =
  | Claim_member of string
  | Conflict_member of string
  | Excluded of string

type pending_fact =
  { fact : fact_ref
  ; claim : string
  }

let ( let* ) = Result.bind
let schema = "workspace.memory.ledger.v1"
let ordinary_store_name = "ordinary"
let source_bound_store_name = "source_bound"

let compare_fact_ref a b =
  let key = function
    | Ordinary { keeper_id; claim_sha256 } -> keeper_id, 0, "", claim_sha256
    | Source_bound { keeper_id; path; claim_sha256 } -> keeper_id, 1, path, claim_sha256
  in
  let keeper_a, store_a, path_a, hash_a = key a
  and keeper_b, store_b, path_b, hash_b = key b in
  match String.compare keeper_a keeper_b with
  | 0 ->
    (match Int.compare store_a store_b with
     | 0 ->
       (match String.compare path_a path_b with
        | 0 -> String.compare hash_a hash_b
        | order -> order)
     | order -> order)
  | order -> order

module Fact_map = Map.Make (struct
    type t = fact_ref
    let compare = compare_fact_ref
  end)

module String_map = Map.Make (String)
module String_set = Set_util.StringSet

type t =
  { claims : string String_map.t
  ; conflicts : string String_map.t
  ; dispositions : disposition Fact_map.t
  }

type reconciliation =
  { ledger : t
  ; current_facts : pending_fact list
  ; new_facts : pending_fact list
  ; vanished : fact_ref list
  }

let empty =
  { claims = String_map.empty; conflicts = String_map.empty; dispositions = Fact_map.empty }

let claims t = String_map.bindings t.claims
let conflicts t = String_map.bindings t.conflicts
let dispositions t = Fact_map.bindings t.dispositions

let named_entries dispositions =
  Fact_map.fold
    (fun _ disposition (claims, conflicts) ->
       match disposition with
       | Claim_member id -> String_set.add id claims, conflicts
       | Conflict_member id -> claims, String_set.add id conflicts
       | Excluded _ -> claims, conflicts)
    dispositions
    (String_set.empty, String_set.empty)

let remove facts t =
  let dispositions = List.fold_left (fun map fact -> Fact_map.remove fact map) t.dispositions facts in
  let named_claims, named_conflicts = named_entries dispositions in
  { claims = String_map.filter (fun id _ -> String_set.mem id named_claims) t.claims
  ; conflicts = String_map.filter (fun id _ -> String_set.mem id named_conflicts) t.conflicts
  ; dispositions
  }

(* Codec *)

let fact_ref_fields = function
  | Ordinary { keeper_id; claim_sha256 } ->
    [ "keeper_id", `String keeper_id
    ; "store", `String ordinary_store_name
    ; "claim_sha256", `String claim_sha256 ]
  | Source_bound { keeper_id; path; claim_sha256 } ->
    [ "keeper_id", `String keeper_id
    ; "store", `String source_bound_store_name
    ; "path", `String path
    ; "claim_sha256", `String claim_sha256 ]

let disposition_json = function
  | Claim_member claim_id -> `Assoc ["kind", `String "claim"; "claim_id", `String claim_id]
  | Conflict_member conflict_id ->
    `Assoc ["kind", `String "conflict"; "conflict_id", `String conflict_id]
  | Excluded reason -> `Assoc ["kind", `String "excluded"; "reason", `String reason]

let to_json t =
  `Assoc
    [ "schema", `String schema
    ; ( "claims"
      , `List (List.map (fun (claim_id, claim) ->
          `Assoc ["claim_id", `String claim_id; "claim", `String claim]) (claims t)) )
    ; ( "conflicts"
      , `List (List.map (fun (conflict_id, description) ->
          `Assoc ["conflict_id", `String conflict_id; "description", `String description])
          (conflicts t)) )
    ; ( "facts"
      , `List (List.map (fun (fact, disposition) ->
          `Assoc (fact_ref_fields fact @ ["disposition", disposition_json disposition]))
          (dispositions t)) ) ]

let rec traverse f = function
  | [] -> Ok []
  | x :: xs ->
    let* y = f x in
    let* ys = traverse f xs in
    Ok (y :: ys)

(* Duplicate keys survive parsing as repeated pairs, so comparing the sorted
   key list with the expected one refuses them along with unknown and missing
   fields. After this check [List.assoc] finds every expected field. *)
let exact_fields ~what names = function
  | `Assoc fields
    when List.equal String.equal
           (List.sort String.compare (List.map fst fields))
           (List.sort String.compare names) -> Ok fields
  | `Assoc _ -> Error (what ^ " has unknown, missing or repeated fields")
  | _ -> Error (what ^ " must be an object")

let nonblank ~what = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error (what ^ " must be a nonblank string")

let is_lower_hex = function '0' .. '9' | 'a' .. 'f' -> true | _ -> false

let sha256_hex ~what = function
  | `String value when String.length value = 64 && String.for_all is_lower_hex value -> Ok value
  | _ -> Error (what ^ " must be 64 lowercase hex digits")

let array ~what = function
  | `List values -> Ok values
  | _ -> Error (what ^ " must be an array")

let decode_disposition json =
  let kind = match json with
    | `Assoc fields -> List.assoc_opt "kind" fields
    | _ -> None
  in
  match kind with
  | Some (`String "claim") ->
    let* fields = exact_fields ~what:"claim disposition" ["kind"; "claim_id"] json in
    let* claim_id = nonblank ~what:"claim_id" (List.assoc "claim_id" fields) in
    Ok (Claim_member claim_id)
  | Some (`String "conflict") ->
    let* fields = exact_fields ~what:"conflict disposition" ["kind"; "conflict_id"] json in
    let* conflict_id = nonblank ~what:"conflict_id" (List.assoc "conflict_id" fields) in
    Ok (Conflict_member conflict_id)
  | Some (`String "excluded") ->
    let* fields = exact_fields ~what:"excluded disposition" ["kind"; "reason"] json in
    let* reason = nonblank ~what:"reason" (List.assoc "reason" fields) in
    Ok (Excluded reason)
  | _ -> Error "disposition kind must be claim, conflict or excluded"

let decode_fact json =
  let store = match json with
    | `Assoc fields -> List.assoc_opt "store" fields
    | _ -> None
  in
  let* fields, fact_of_fields =
    match store with
    | Some (`String name) when String.equal name ordinary_store_name ->
      let* fields =
        exact_fields ~what:"ordinary fact" ["keeper_id"; "store"; "claim_sha256"; "disposition"] json
      in
      Ok (fields, fun ~keeper_id ~claim_sha256 -> Ok (Ordinary { keeper_id; claim_sha256 }))
    | Some (`String name) when String.equal name source_bound_store_name ->
      let* fields =
        exact_fields ~what:"source-bound fact"
          ["keeper_id"; "store"; "path"; "claim_sha256"; "disposition"] json
      in
      Ok (fields, fun ~keeper_id ~claim_sha256 ->
        let* path = nonblank ~what:"path" (List.assoc "path" fields) in
        Ok (Source_bound { keeper_id; path; claim_sha256 }))
    | _ -> Error "fact store must be ordinary or source_bound"
  in
  let* keeper_id = nonblank ~what:"keeper_id" (List.assoc "keeper_id" fields) in
  let* claim_sha256 = sha256_hex ~what:"claim_sha256" (List.assoc "claim_sha256" fields) in
  let* fact = fact_of_fields ~keeper_id ~claim_sha256 in
  let* disposition = decode_disposition (List.assoc "disposition" fields) in
  Ok (fact, disposition)

let decode_entry ~what ~id_field ~text_field json =
  let* fields = exact_fields ~what [id_field; text_field] json in
  let* id = nonblank ~what:id_field (List.assoc id_field fields) in
  let* text = nonblank ~what:text_field (List.assoc text_field fields) in
  Ok (id, text)

let unique_entries ~what entries =
  List.fold_left
    (fun map (id, text) ->
       let* map = map in
       if String_map.mem id map then Error (Printf.sprintf "%s %S is listed twice" what id)
       else Ok (String_map.add id text map))
    (Ok String_map.empty)
    entries

let check_references t =
  let* () =
    Fact_map.fold
      (fun _ disposition checked ->
         let* () = checked in
         match disposition with
         | Claim_member id when not (String_map.mem id t.claims) ->
           Error (Printf.sprintf "a fact names absent claim_id %S" id)
         | Conflict_member id when not (String_map.mem id t.conflicts) ->
           Error (Printf.sprintf "a fact names absent conflict_id %S" id)
         | Claim_member _ | Conflict_member _ | Excluded _ -> Ok ())
      t.dispositions
      (Ok ())
  in
  let named_claims, named_conflicts = named_entries t.dispositions in
  let unnamed ~what named entries =
    match List.find_opt (fun (id, _) -> not (String_set.mem id named)) (String_map.bindings entries) with
    | Some (id, _) -> Error (Printf.sprintf "%s %S has no member" what id)
    | None -> Ok ()
  in
  let* () = unnamed ~what:"claim" named_claims t.claims in
  unnamed ~what:"conflict" named_conflicts t.conflicts

let of_json json =
  let* fields = exact_fields ~what:"ledger" ["schema"; "claims"; "conflicts"; "facts"] json in
  let* () =
    match List.assoc "schema" fields with
    | `String value when String.equal value schema -> Ok ()
    | _ -> Error ("ledger schema must be " ^ schema)
  in
  let* claims = array ~what:"claims" (List.assoc "claims" fields) in
  let* claims =
    traverse (decode_entry ~what:"claim" ~id_field:"claim_id" ~text_field:"claim") claims
  in
  let* claims = unique_entries ~what:"claim_id" claims in
  let* conflicts = array ~what:"conflicts" (List.assoc "conflicts" fields) in
  let* conflicts =
    traverse (decode_entry ~what:"conflict" ~id_field:"conflict_id" ~text_field:"description")
      conflicts
  in
  let* conflicts = unique_entries ~what:"conflict_id" conflicts in
  let* facts = array ~what:"facts" (List.assoc "facts" fields) in
  let* facts = traverse decode_fact facts in
  let* dispositions =
    List.fold_left
      (fun map (fact, disposition) ->
         let* map = map in
         if Fact_map.mem fact map then Error "a fact is listed twice"
         else Ok (Fact_map.add fact disposition map))
      (Ok Fact_map.empty)
      facts
  in
  let t = { claims; conflicts; dispositions } in
  let* () = check_references t in
  Ok t

(* Store *)

let directory ~base_path =
  Filename.concat (Filename.concat base_path Common.masc_dirname) "workspace-memory"

let path ~base_path = Filename.concat (directory ~base_path) "ledger.json"

let io f =
  try f () with
  | Unix.Unix_error (error, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error))
  | Sys_error detail -> Error detail
  | Eio.Io _ as exn -> Error (Printexc.to_string exn)

(* A base path that does not exist is a wrong path, not a fresh workspace.
   [save] would otherwise create it and [load] would read it as [empty]. *)
let require_base ~base_path =
  if Sys.is_directory base_path then Ok ()
  else Error (base_path ^ ": workspace base is not a directory")

let load ~base_path =
  io (fun () ->
    let* () = require_base ~base_path in
    let path = path ~base_path in
    match Fs_compat.load_file_opt path with
    | None -> Ok empty
    | Some text ->
      let* json =
        try Ok (Yojson.Safe.from_string text) with
        | Yojson.Json_error detail -> Error (path ^ ": " ^ detail)
      in
      of_json json |> Result.map_error (fun detail -> path ^ ": " ^ detail))

let save ~base_path t =
  io (fun () ->
    let* () = require_base ~base_path in
    Fs_compat.mkdir_p (directory ~base_path);
    match Fs_compat.save_file_atomic_strict_staged (path ~base_path)
            (Yojson.Safe.to_string (to_json t)) with
    | Ok () -> Ok ()
    | Error failure ->
      (match failure.exception_ with
       | Eio.Cancel.Cancelled _ as exn -> Printexc.raise_with_backtrace exn failure.backtrace
       | _ -> Error (Fs_compat.atomic_replace_failure_to_string failure)))

(* The digest a Keeper turn sees without a tool call: one opening line per
   claim, in claim_id order, under a byte budget. Full claim bodies stay
   behind [keeper_workspace_memory_read]; a line cut mid-character would not
   round-trip through the prompt, so the cut follows [String_util.utf8_prefix]. *)
let digest_line_max_bytes = 160
let digest_budget_bytes = 8192

let digest_line (claim_id, claim) =
  let first_line = match String.index_opt claim '\n' with
    | None -> claim
    | Some cut -> String.sub claim 0 cut in
  let prefix = String_util.utf8_prefix ~max_bytes:digest_line_max_bytes first_line in
  let ellipsized =
    if String.length prefix < String.length first_line then prefix ^ "…"
    else prefix in
  "- " ^ claim_id ^ ": " ^ ellipsized

let claims_digest ledger =
  (* The budget bounds what the prompt renders, so the join newline between
     two lines counts with the line that introduces it. *)
  let rec take_budget spent acc = function
    | [] -> List.rev acc, false
    | (claim_id, _) as row :: rest ->
      let line = digest_line row in
      let spent' = spent + String.length line + 1 in
      if spent' > digest_budget_bytes && acc <> [] then List.rev acc, true
      else take_budget spent' (line :: acc) rest
  in
  take_budget 0 [] (claims ledger)

type observation =
  | Missing
  | Unavailable of string
  | Available of
      { ledger_sha256 : string
      ; claim_count : int
      ; conflict_count : int
      ; classified_count : int
      ; claims_digest : string list
      }

let observe ~base_path =
  let ledger_path = path ~base_path in
  try
    match Unix.lstat ledger_path with
    | { Unix.st_kind = Unix.S_REG; _ } ->
      let stored = io (fun () ->
        let text = Fs_compat.load_file ledger_path in
        let* json = try Ok (Yojson.Safe.from_string text)
          with Yojson.Json_error detail -> Error (ledger_path ^ ": " ^ detail) in
        of_json json |> Result.map_error (fun detail -> ledger_path ^ ": " ^ detail)) in
      (match stored with
       | Error detail -> Unavailable detail
       | Ok ledger ->
         let ledger_sha256 = Digestif.SHA256.(digest_string
           (Yojson.Safe.to_string (to_json ledger)) |> to_hex) in
         let digest, _truncated = claims_digest ledger in
         Available { ledger_sha256; claim_count = List.length (claims ledger);
                     conflict_count = List.length (conflicts ledger);
                     classified_count = List.length (dispositions ledger);
                     claims_digest = digest })
    | _ -> Unavailable (ledger_path ^ ": not a regular file")
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Missing
  | Unix.Unix_error (error, fn, arg) ->
    Unavailable (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error))

(* Reconciliation *)

let claim_sha256 claim = Digestif.SHA256.(digest_string claim |> to_hex)

type store_key =
  | Ordinary_store of string
  | Source_bound_store of string

let store_key = function
  | Ordinary { keeper_id; _ } -> Ordinary_store keeper_id
  | Source_bound { keeper_id; _ } -> Source_bound_store keeper_id

let same_store a b =
  match a, b with
  | Ordinary_store a, Ordinary_store b | Source_bound_store a, Source_bound_store b ->
    String.equal a b
  | Ordinary_store _, Source_bound_store _ | Source_bound_store _, Ordinary_store _ -> false

(* [None] is a store this run could not read. [Missing] is a read store that
   holds nothing. *)
let facts_of_observation observation facts =
  match observation with
  | Workspace_memory_context.Unavailable _ -> None
  | Workspace_memory_context.Missing -> Some []
  | Workspace_memory_context.Available snapshot -> Some (facts snapshot)

let observe_keeper (keeper : Workspace_memory_context.keeper) =
  let keeper_id = keeper.keeper_id in
  [ ( Ordinary_store keeper_id
    , facts_of_observation keeper.ordinary (fun (snapshot : Keeper_memory_os_current.t) ->
        List.map (fun (fact : Keeper_memory_os_types.fact) ->
          { fact = Ordinary { keeper_id; claim_sha256 = claim_sha256 fact.claim }
          ; claim = fact.claim })
          snapshot.facts) )
  ; ( Source_bound_store keeper_id
    , facts_of_observation keeper.source_bound (fun (snapshot : Keeper_memory_source_current.t) ->
        List.map (fun (fact : Keeper_memory_source_current.fact) ->
          { fact = Source_bound
                { keeper_id; path = fact.source.path; claim_sha256 = claim_sha256 fact.claim }
          ; claim = fact.claim })
          snapshot.facts) ) ]

let reconcile t keepers =
  let stores = List.concat_map observe_keeper keepers in
  let unreadable =
    List.filter_map (fun (key, facts) -> match facts with None -> Some key | Some _ -> None) stores
  in
  (* A store may list one claim twice; its identity is one fact. *)
  let current, observed_order =
    List.fold_left
      (fun (current, order) (_, facts) ->
         List.fold_left
           (fun (current, order) pending ->
              if Fact_map.mem pending.fact current then current, order
              else Fact_map.add pending.fact () current, pending :: order)
           (current, order)
           (Option.to_list facts |> List.concat))
      (Fact_map.empty, [])
      stores
  in
  let current_facts = List.rev observed_order in
  let new_facts =
    current_facts
    |> List.filter (fun pending -> not (Fact_map.mem pending.fact t.dispositions))
  in
  let vanished =
    Fact_map.fold
      (fun fact _ vanished ->
         if Fact_map.mem fact current
            || List.exists (same_store (store_key fact)) unreadable
         then vanished
         else fact :: vanished)
      t.dispositions
      []
    |> List.rev
  in
  { ledger = remove vanished t; current_facts; new_facts; vanished }

type decision =
  | Join_claim of string
  | Create_claim of string
  | Join_conflict of string
  | Create_conflict of string
  | Exclude of string

type assignment = { fact : fact_ref; decision : decision }

type apply_error =
  | Duplicate_selected_fact
  | Duplicate_assignment
  | Unselected_fact
  | Missing_assignment
  | Already_disposed
  | Unknown_claim of string
  | Unknown_conflict of string
  | Blank_value
  | Id_collision
  | Invalid_result of string

let apply_error_to_string = function
  | Duplicate_selected_fact -> "workspace curator selected one fact more than once"
  | Duplicate_assignment -> "workspace curator assigned one fact more than once"
  | Unselected_fact -> "workspace curator assigned a fact outside the selected batch"
  | Missing_assignment -> "workspace curator did not assign every selected fact"
  | Already_disposed -> "workspace curator tried to replace an existing disposition"
  | Unknown_claim id -> "workspace curator named an unknown claim: " ^ id
  | Unknown_conflict id -> "workspace curator named an unknown conflict: " ^ id
  | Blank_value -> "workspace curator decision has a blank value"
  | Id_collision -> "workspace curator result id collides with different text"
  | Invalid_result detail -> "workspace curator ledger result: " ^ detail

let id_of_text ~kind text =
  kind ^ "-" ^ Digestif.SHA256.(digest_string text |> to_hex)

let apply t ~selected assignments =
  let selected_refs = List.map (fun (pending : pending_fact) -> pending.fact) selected in
  let selected_set = List.fold_left (fun set fact -> Fact_map.add fact () set)
    Fact_map.empty selected_refs in
  if Fact_map.cardinal selected_set <> List.length selected_refs
  then Error Duplicate_selected_fact
  else if List.length assignments <> List.length selected_refs
  then Error Missing_assignment
  else
    let rec add current seen = function
      | [] ->
        if Fact_map.cardinal seen <> Fact_map.cardinal selected_set
        then Error Missing_assignment
        else check_references current
          |> Result.map_error (fun detail -> Invalid_result detail)
          |> Result.map (fun () -> current)
      | { fact; decision } :: rest ->
        if not (Fact_map.mem fact selected_set) then Error Unselected_fact
        else if Fact_map.mem fact seen then Error Duplicate_assignment
        else if Fact_map.mem fact current.dispositions then Error Already_disposed
        else
          let ( let* ) = Result.bind in
          let* next, disposition =
            match decision with
            | Join_claim id ->
              if String_map.mem id t.claims
              then Ok (current, Claim_member id)
              else Error (Unknown_claim id)
            | Join_conflict id ->
              if String_map.mem id t.conflicts
              then Ok (current, Conflict_member id)
              else Error (Unknown_conflict id)
            | Exclude reason ->
              if String.trim reason = ""
              then Error Blank_value
              else Ok (current, Excluded reason)
            | Create_claim claim ->
              if String.trim claim = "" then Error Blank_value else
              let id = id_of_text ~kind:"claim" claim in
              (match String_map.find_opt id current.claims with
               | Some other when not (String.equal other claim) -> Error Id_collision
               | Some _ -> Ok (current, Claim_member id)
               | None ->
                 Ok ({ current with claims = String_map.add id claim current.claims },
                     Claim_member id))
            | Create_conflict description ->
              if String.trim description = "" then Error Blank_value else
              let id = id_of_text ~kind:"conflict" description in
              (match String_map.find_opt id current.conflicts with
               | Some other when not (String.equal other description) -> Error Id_collision
               | Some _ -> Ok (current, Conflict_member id)
               | None ->
                 Ok ({ current with conflicts = String_map.add id description current.conflicts },
                     Conflict_member id))
          in
          add { next with dispositions = Fact_map.add fact disposition next.dispositions }
            (Fact_map.add fact () seen) rest
    in
    add t Fact_map.empty assignments
