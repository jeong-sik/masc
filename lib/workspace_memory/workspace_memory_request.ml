module Ledger = Workspace_memory_ledger
module Index = Keeper_memory_search_index

type error =
  | Invalid_limit
  | Render_failed of string
  | Index_unavailable of string
  | Invalid_batch of string

type row = { fact : Ledger.pending_fact; neighbors : Ledger.pending_fact list }

type ids =
  { fact_ids : (string * Ledger.fact_ref) list
  ; claim_ids : (string * string) list
  ; conflict_ids : (string * string) list
  }

type batch =
  { rows : row list
  ; selected : Ledger.pending_fact list
  ; input : Yojson.Safe.t
  ; rendered_prompt : string
  ; ids : ids
  ; index_stats : Index.batch_stats
  }

let error_to_string = function
  | Invalid_limit -> "workspace curator neighbor limit must be nonnegative"
  | Render_failed detail -> "workspace curator prompt render: " ^ detail
  | Index_unavailable detail -> "workspace curator neighbor index: " ^ detail
  | Invalid_batch detail -> "workspace curator inconsistent request: " ^ detail

let ( let* ) = Result.bind

module Fact_map = Map.Make (struct
    type t = Ledger.fact_ref
    let compare = Stdlib.compare
  end)
module String_map = Map.Make (String)

let keeper_id = function
  | Ledger.Ordinary { keeper_id; _ } | Ledger.Source_bound { keeper_id; _ } -> keeper_id

let path_json = function
  | Ledger.Ordinary _ -> `Null
  | Ledger.Source_bound { path; _ } -> `String path

let claim_sha256 = function
  | Ledger.Ordinary { claim_sha256; _ } | Ledger.Source_bound { claim_sha256; _ } -> claim_sha256

let rec traverse f = function
  | [] -> Ok []
  | x :: xs ->
    let* y = f x in
    let* ys = traverse f xs in
    Ok (y :: ys)

(* A local id names one fact, claim or conflict inside one request. Facts are
   numbered by first appearance: every selected fact oldest first, then each
   neighbor the first time a row names it. The model reads each text once and
   the host keeps the map back to ledger identities. *)
type numbering = { order : (string * Ledger.pending_fact) list; index : string Fact_map.t }

let number numbering (pending : Ledger.pending_fact) =
  match Fact_map.find_opt pending.fact numbering.index with
  | Some _ -> numbering
  | None ->
    let id = "f" ^ string_of_int (Fact_map.cardinal numbering.index + 1) in
    { order = (id, pending) :: numbering.order; index = Fact_map.add pending.fact id numbering.index }

let local numbering (pending : Ledger.pending_fact) =
  match Fact_map.find_opt pending.fact numbering.index with
  | Some id -> Ok id
  | None -> Error "a request row names a fact outside its numbering"

type entries = { listed : (string * string) list; by_id : string String_map.t }

let no_entries = { listed = []; by_id = String_map.empty }

let entry prefix entries id =
  match String_map.find_opt id entries.by_id with
  | Some local -> local, entries
  | None ->
    let local = prefix ^ string_of_int (String_map.cardinal entries.by_id + 1) in
    local, { listed = (local, id) :: entries.listed; by_id = String_map.add id local entries.by_id }

let texts pairs =
  List.fold_left (fun map (id, text) -> String_map.add id text map) String_map.empty pairs

let build ~ledger rows =
  let dispositions =
    List.fold_left (fun map (fact, disposition) -> Fact_map.add fact disposition map)
      Fact_map.empty (Ledger.dispositions ledger) in
  let numbering =
    List.fold_left number { order = []; index = Fact_map.empty } (List.map (fun row -> row.fact) rows) in
  let numbering =
    List.fold_left (fun numbering row -> List.fold_left number numbering row.neighbors) numbering rows in
  let facts = List.rev numbering.order in
  let shown, claims, conflicts =
    List.fold_left (fun (shown, claims, conflicts) (id, (pending : Ledger.pending_fact)) ->
      let member_of, claims, conflicts =
        match Fact_map.find_opt pending.fact dispositions with
        | Some (Ledger.Claim_member claim_id) ->
          let local, claims = entry "c" claims claim_id in `String local, claims, conflicts
        | Some (Ledger.Conflict_member conflict_id) ->
          let local, conflicts = entry "x" conflicts conflict_id in `String local, claims, conflicts
        | Some (Ledger.Excluded _) | None -> `Null, claims, conflicts in
      `Assoc ["id", `String id; "keeper", `String (keeper_id pending.fact);
              "path", path_json pending.fact; "claim", `String pending.claim;
              "member_of", member_of] :: shown, claims, conflicts)
      ([], no_entries, no_entries) facts in
  let table field known entries =
    traverse (fun (local, id) -> match String_map.find_opt id known with
      | Some text -> Ok (`Assoc ["id", `String local; field, `String text])
      | None -> Error "the captured ledger names an absent claim or conflict")
      (List.rev entries.listed) in
  let* claim_rows = table "claim" (texts (Ledger.claims ledger)) claims in
  let* conflict_rows = table "description" (texts (Ledger.conflicts ledger)) conflicts in
  let* new_facts = traverse (fun row ->
      let* id = local numbering row.fact in
      let* neighbors = traverse (local numbering) row.neighbors in
      Ok (`Assoc ["id", `String id; "neighbors", `List (List.map (fun id -> `String id) neighbors)]))
      rows in
  Ok (`Assoc ["new_facts", `List new_facts; "facts", `List (List.rev shown);
              "claims", `List claim_rows; "conflicts", `List conflict_rows],
      { fact_ids = List.map (fun (id, (pending : Ledger.pending_fact)) -> id, pending.fact) facts
      ; claim_ids = List.rev claims.listed
      ; conflict_ids = List.rev conflicts.listed })

let check_rows rows =
  let rec selected seen = function
    | [] -> Ok ()
    | (row : row) :: rest ->
      if Fact_map.mem row.fact.fact seen then Error "a request selects one fact twice"
      else selected (Fact_map.add row.fact.fact () seen) rest in
  let neighbors (row : row) =
    let owner = keeper_id row.fact.fact in
    let rec loop seen = function
      | [] -> Ok ()
      | (neighbor : Ledger.pending_fact) :: rest ->
        if String.equal (keeper_id neighbor.fact) owner
        then Error "a neighbor belongs to the selected fact's Keeper"
        else if Fact_map.mem neighbor.fact seen then Error "a row repeats a neighbor"
        else loop (Fact_map.add neighbor.fact () seen) rest in
    loop Fact_map.empty row.neighbors in
  let* () = selected Fact_map.empty rows in
  let* _ = traverse neighbors rows in
  Ok ()

let render_batch ~render ~ledger ~index_stats rows =
  let* input, ids = build ~ledger rows |> Result.map_error (fun detail -> Invalid_batch detail) in
  let* rendered_prompt = render input |> Result.map_error (fun detail -> Render_failed detail) in
  Ok { rows; selected = List.map (fun (row : row) -> row.fact) rows; input; rendered_prompt; ids; index_stats }

let selected_ids batch =
  let ids =
    List.fold_left (fun map (id, fact) -> Fact_map.add fact id map) Fact_map.empty batch.ids.fact_ids in
  List.filter_map (fun (pending : Ledger.pending_fact) ->
    Option.map (fun id -> id, pending) (Fact_map.find_opt pending.fact ids)) batch.selected

let claim_ids batch = batch.ids.claim_ids
let conflict_ids batch = batch.ids.conflict_ids

let batch_schema = "workspace.memory.classification-batch.v2"

let batch_to_json (batch : batch) =
  let stats = batch.index_stats in
  let pairs field values =
    `List (List.map (fun (local, value) -> `Assoc ["id", `String local; field, value]) values) in
  `Assoc ["schema", `String batch_schema; "input", batch.input;
    "rendered_prompt", `String batch.rendered_prompt;
    "facts", pairs "fact" (List.map (fun (id, fact) -> id, Ledger.fact_ref_to_json fact) batch.ids.fact_ids);
    "claims", pairs "claim_id" (List.map (fun (id, claim) -> id, `String claim) batch.ids.claim_ids);
    "conflicts", pairs "conflict_id"
      (List.map (fun (id, conflict) -> id, `String conflict) batch.ids.conflict_ids);
    "index_stats", `Assoc ["index_builds", `Int stats.index_builds;
      "indexed_rows", `Int stats.indexed_rows; "queries_executed", `Int stats.queries_executed]]

let snapshot_fields names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error "batch snapshot has unknown, missing or repeated fields"
let snapshot_text = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error "batch snapshot expects nonblank text"
let snapshot_array decode = function
  | `List rows -> traverse decode rows
  | _ -> Error "batch snapshot expects an array"
let snapshot_pairs field decode json =
  snapshot_array (fun row ->
    let* fields = snapshot_fields ["id"; field] row in
    let* id = snapshot_text (List.assoc "id" fields) in
    let* value = decode (List.assoc field fields) in
    Ok (id, value)) json

let batch_of_json ~ledger json =
  let decode () =
    let* fields = snapshot_fields
        ["schema"; "input"; "rendered_prompt"; "facts"; "claims"; "conflicts"; "index_stats"] json in
    let* schema = snapshot_text (List.assoc "schema" fields) in
    let* () = if String.equal schema batch_schema then Ok () else Error "unknown classification batch schema" in
    let* fact_ids = snapshot_pairs "fact" Ledger.fact_ref_of_json (List.assoc "facts" fields) in
    let* claim_ids = snapshot_pairs "claim_id" snapshot_text (List.assoc "claims" fields) in
    let* conflict_ids = snapshot_pairs "conflict_id" snapshot_text (List.assoc "conflicts" fields) in
    let input = List.assoc "input" fields in
    let* input_fields = snapshot_fields ["new_facts"; "facts"; "claims"; "conflicts"] input in
    let* shown = snapshot_array (fun row ->
        let* fields = snapshot_fields ["id"; "keeper"; "path"; "claim"; "member_of"] row in
        let* id = snapshot_text (List.assoc "id" fields) in
        let* claim = snapshot_text (List.assoc "claim" fields) in
        Ok (id, claim)) (List.assoc "facts" input_fields) in
    let refs = texts fact_ids and claims = texts shown in
    let pending id =
      match String_map.find_opt id refs, String_map.find_opt id claims with
      | Some fact, Some claim ->
        if String.equal (claim_sha256 fact) Digestif.SHA256.(digest_string claim |> to_hex)
        then Ok { Ledger.fact; claim } else Error "snapshot claim does not match its source hash"
      | None, (None | Some _) | Some _, None -> Error "snapshot names a fact outside its id map" in
    let* rows = snapshot_array (fun row ->
        let* fields = snapshot_fields ["id"; "neighbors"] row in
        let* fact = let* id = snapshot_text (List.assoc "id" fields) in pending id in
        let* neighbors = snapshot_array (fun neighbor -> let* id = snapshot_text neighbor in pending id)
            (List.assoc "neighbors" fields) in
        Ok { fact; neighbors }) (List.assoc "new_facts" input_fields) in
    let* () = if rows = [] then Error "classification batch has no selected facts" else check_rows rows in
    let disposed =
      List.fold_left (fun map (fact, _) -> Fact_map.add fact () map) Fact_map.empty (Ledger.dispositions ledger) in
    let* () = if List.exists (fun (row : row) -> Fact_map.mem row.fact.fact disposed) rows
      then Error "snapshot selected fact already has a captured ledger disposition" else Ok () in
    (* The captured ledger decides every membership and entry text the model
       saw. Rebuilding from the rows and that ledger and requiring equality
       binds the request to the before-state its commit changes. *)
    let* expected, ids = build ~ledger rows in
    let* () = if Yojson.Safe.equal expected input && ids = { fact_ids; claim_ids; conflict_ids } then Ok ()
      else Error "snapshot differs from its selected facts or captured ledger context" in
    let* rendered_prompt = snapshot_text (List.assoc "rendered_prompt" fields) in
    let* stats = snapshot_fields ["index_builds"; "indexed_rows"; "queries_executed"] (List.assoc "index_stats" fields) in
    let count key = match List.assoc key stats with
      | `Int count when count >= 0 -> Ok count
      | _ -> Error "snapshot index statistics must be nonnegative integers" in
    let* index_builds = count "index_builds" in
    let* indexed_rows = count "indexed_rows" in
    let* queries_executed = count "queries_executed" in
    Ok { rows; selected = List.map (fun (row : row) -> row.fact) rows; input; rendered_prompt; ids;
         index_stats = { Index.index_builds; indexed_rows; queries_executed } } in
  decode () |> Result.map_error (fun detail -> Invalid_batch detail)

let prepare ~neighbor_limit ~render ~ledger ~current ~pending =
  if neighbor_limit < 0 then Error Invalid_limit
  else match pending with
  | [] -> Ok None
  | _ :: _ ->
    let texts = List.map (fun (fact : Ledger.pending_fact) ->
      keeper_id fact.fact, fact.claim) current in
    let queries = List.map (fun (fact : Ledger.pending_fact) ->
      keeper_id fact.fact, fact.claim) pending in
    let* rankings, index_stats =
      Index.rank_many_excluding_owners ~queries ~texts ~max_results:neighbor_limit
      |> Result.map_error (fun error -> Index_unavailable (Index.error_to_string error)) in
    let sources = Array.of_list current in
    let rows = List.map2 (fun fact ranked ->
      { fact; neighbors = List.map (fun (ordinal, _) -> sources.(ordinal)) ranked }) pending rankings in
    let* batch = render_batch ~render ~ledger ~index_stats rows in
    Ok (Some batch)

let narrow ~render ~ledger batch =
  match batch.rows with
  | [] | [_] -> Ok None
  | _ :: _ :: _ ->
    (* Finite whole-row bisection follows an actual provider refusal. It reads
       only the parent rows and the parent's captured ledger, so one parent
       always yields the same child. This is not a byte/token estimate and
       never trims a row's neighbors. *)
    let rows = List.take (List.length batch.rows / 2) batch.rows in
    let* child = render_batch ~render ~ledger ~index_stats:batch.index_stats rows in
    Ok (Some child)
