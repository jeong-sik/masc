module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_access_policy — shared allow/deny selector ADT for runtime tool policies. *)

module StringSet = Set_util.StringSet

type selector =
  | Empty
  | All
  | Names of string list
  | Union of selector list
  | Inter of selector list
  | Diff of { base : selector; exclude : selector }

type t = {
  allow : selector;
  deny : selector;
}

let normalize_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> not (String.equal name ""))
  |> Json_util.dedupe_keep_order

let empty = { allow = Empty; deny = Empty }
let allow_all = { allow = All; deny = Empty }

let of_allowlist ?(deny = []) allow =
  { allow = Names allow; deny = Names deny }

let union selectors =
  match selectors with
  | [] -> Empty
  | [ selector ] -> selector
  | many -> Union many

let inter selectors =
  match selectors with
  | [] -> All
  | [ selector ] -> selector
  | many -> Inter many

let diff ~base ~exclude =
  match (base, exclude) with
  | Empty, _ -> Empty
  | _, Empty -> base
  | _ -> Diff { base; exclude }

let with_deny_selector policy selector =
  {
    policy with
    deny =
      (match (policy.deny, selector) with
      | Empty, other -> other
      | existing, Empty -> existing
      | existing, other -> Union [ existing; other ]);
  }

let with_deny_names policy names =
  with_deny_selector policy (Names names)

(* Membership-only normalization: skip empties + trim, but skip the
   StringSet dedup that [normalize_names] performs (duplicates do not
   change membership).  Short-circuits on first match via [List.exists]. *)
let name_in_normalized_list name candidates =
  List.exists
    (fun candidate ->
      let trimmed = String.trim candidate in
      (not (String.equal trimmed ""))
      && String.equal trimmed name)
    candidates

let rec selector_matches_name selector name =
  match selector with
  | Empty -> false
  | All -> true
  | Names names ->
      name_in_normalized_list name names
  | Union selectors ->
      List.exists (fun item -> selector_matches_name item name) selectors
  | Inter selectors ->
      List.for_all (fun item -> selector_matches_name item name) selectors
  | Diff { base; exclude } ->
      selector_matches_name base name
      && not (selector_matches_name exclude name)

let allows_name policy name =
  selector_matches_name policy.allow name
  && not (selector_matches_name policy.deny name)

(* Union of actor-facing and system-internal curated tool-name lists.  Replaces the former
   [all_surfaces |> concat_map tools_for_surface] iteration over the deleted
   [surface] type.  normalize_names dedupes. *)
let default_candidates () =
  ( Tool_catalog_surfaces.public_mcp_surface_tools
  @ Tool_catalog_surfaces.spawned_agent_surface_tools
  @ Tool_catalog_surfaces.local_worker_surface_tools
  @ Tool_catalog_surfaces.session_min_surface_tools
  @ Tool_catalog_surfaces.system_internal_hidden )
  |> normalize_names

let rec resolve_selector ?candidates selector =
  match selector with
  | Empty -> []
  | All ->
      normalize_names
        (match candidates with
        | Some names -> names
        | None -> default_candidates ())
  | Names names -> normalize_names names
  | Union selectors ->
      selectors
      |> List.concat_map (resolve_selector ?candidates)
      |> normalize_names
  | Inter selectors ->
      (match selectors with
      | [] ->
          normalize_names
            (match candidates with
            | Some names -> names
            | None -> default_candidates ())
      | first :: rest ->
          let first_set = resolve_selector ?candidates first in
          List.fold_left
            (fun acc sel ->
              let resolved_set =
                StringSet.of_list (resolve_selector ?candidates sel)
              in
              List.filter (fun name -> StringSet.mem name resolved_set) acc)
            first_set rest
          |> normalize_names)
  | Diff { base; exclude } ->
      let base_resolved = resolve_selector ?candidates base in
      let exclude_set =
        StringSet.of_list (resolve_selector ?candidates exclude)
      in
      base_resolved
      |> List.filter (fun name -> not (StringSet.mem name exclude_set))
      |> normalize_names

let resolve ?candidates policy =
  let allowed = resolve_selector ?candidates policy.allow in
  let denied_set =
    StringSet.of_list (resolve_selector ?candidates policy.deny)
  in
  allowed
  |> List.filter (fun name -> not (StringSet.mem name denied_set))
  |> normalize_names
