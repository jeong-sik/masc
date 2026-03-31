(** Tool_access_policy — shared allow/deny selector ADT for runtime tool policies. *)

type selector =
  | Empty
  | All
  | Names of string list
  | Surface of Tool_catalog.surface
  | Union of selector list

type t = {
  allow : selector;
  deny : selector;
}

let dedupe_keep_order names =
  let seen = Hashtbl.create (max 16 (List.length names)) in
  let rec loop acc = function
    | [] -> List.rev acc
    | name :: rest when Hashtbl.mem seen name -> loop acc rest
    | name :: rest ->
        Hashtbl.replace seen name ();
        loop (name :: acc) rest
  in
  loop [] names

let normalize_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
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

let resolve ?candidates policy =
  let allowed = resolve_selector ?candidates policy.allow in
  let denied = resolve_selector ?candidates policy.deny in
  allowed
  |> List.filter (fun name -> not (List.mem name denied))
  |> normalize_names
