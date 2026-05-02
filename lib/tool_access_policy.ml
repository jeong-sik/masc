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

module StringSet = Set.Make (String)

type selector =
  | Empty
  | All
  | Names of string list
  | Surface of Tool_catalog.surface
  | Union of selector list
  | Inter of selector list
  | Diff of { base : selector; exclude : selector }

type t = {
  allow : selector;
  deny : selector;
}

let dedupe_keep_order names =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | name :: rest when StringSet.mem name seen -> loop seen acc rest
    | name :: rest ->
        loop (StringSet.add name seen) (name :: acc) rest
  in
  loop StringSet.empty [] names

let normalize_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> not (String.equal name ""))
  |> dedupe_keep_order

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

let rec selector_matches_name selector name =
  match selector with
  | Empty -> false
  | All -> true
  | Names names ->
      List.mem name (normalize_names names)
  | Surface surface ->
      Tool_catalog.is_on_surface surface name
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

let default_candidates () =
  Tool_catalog.all_surfaces
  |> List.concat_map Tool_catalog.tools_for_surface
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
  | Surface surface -> normalize_names (Tool_catalog.tools_for_surface surface)
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
              let resolved = resolve_selector ?candidates sel in
              List.filter (fun name -> List.mem name resolved) acc)
            first_set rest
          |> normalize_names)
  | Diff { base; exclude } ->
      let base_resolved = resolve_selector ?candidates base in
      let exclude_resolved = resolve_selector ?candidates exclude in
      base_resolved
      |> List.filter (fun name -> not (List.mem name exclude_resolved))
      |> normalize_names

let resolve ?candidates policy =
  let allowed = resolve_selector ?candidates policy.allow in
  let denied = resolve_selector ?candidates policy.deny in
  allowed
  |> List.filter (fun name -> not (List.mem name denied))
  |> normalize_names
