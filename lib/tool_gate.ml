(** Tool_gate — algebraic tool set operations for zone boundaries.
    Phase 2A of Tool Gate architecture (#4381). *)

type tool_op =
  | Keep_all
  | Clear_all
  | Add of string list
  | Remove of string list
  | Replace_with of string list
  | Intersect_with of string list
  | Seq of tool_op list

type inverse_result =
  | Reversible of tool_op
  | Irreversible

(* ================================================================ *)
(* Local helpers                                                     *)
(* Copied from tool_access_policy.ml (module-private there).         *)
(* Same Hashtbl-based O(n) pattern.                                  *)
(* ================================================================ *)

let set_of_list names =
  let tbl = Hashtbl.create (List.length names) in
  List.iter (fun n -> Hashtbl.replace tbl n ()) names;
  tbl

let dedupe_keep_order names =
  let seen = Hashtbl.create (max 16 (List.length names)) in
  let rec loop acc = function
    | [] -> List.rev acc
    | n :: rest when Hashtbl.mem seen n -> loop acc rest
    | n :: rest ->
        Hashtbl.replace seen n ();
        loop (n :: acc) rest
  in
  loop [] names

let normalize names =
  names
  |> List.map String.trim
  |> List.filter (fun n -> n <> "")
  |> dedupe_keep_order

(* ================================================================ *)
(* apply                                                             *)
(* ================================================================ *)

let rec apply op current =
  let current = normalize current in
  match op with
  | Keep_all -> current
  | Clear_all -> []
  | Add names ->
      let set = set_of_list current in
      let new_names =
        normalize names
        |> List.filter (fun n -> not (Hashtbl.mem set n))
      in
      current @ new_names
  | Remove names ->
      let rm = set_of_list (normalize names) in
      List.filter (fun n -> not (Hashtbl.mem rm n)) current
  | Replace_with names -> normalize names
  | Intersect_with names ->
      let keep = set_of_list (normalize names) in
      List.filter (fun n -> Hashtbl.mem keep n) current
  | Seq ops ->
      List.fold_left (fun acc op -> apply op acc) current ops

(* ================================================================ *)
(* inverse                                                           *)
(* ================================================================ *)

let rec inverse op =
  match op with
  | Keep_all -> Reversible Keep_all
  | Clear_all -> Irreversible
  | Add names -> Reversible (Remove names)
  | Remove names -> Reversible (Add names)
  | Replace_with _ -> Irreversible
  | Intersect_with _ -> Irreversible
  | Seq ops ->
      let rev_inverses =
        List.fold_left
          (fun acc op ->
            match acc with
            | None -> None
            | Some invs -> (
                match inverse op with
                | Reversible inv -> Some (inv :: invs)
                | Irreversible -> None))
          (Some []) ops
      in
      (match rev_inverses with
       | Some [] -> Reversible Keep_all
       | Some invs -> Reversible (Seq invs)
       | None -> Irreversible)

(* ================================================================ *)
(* compose                                                           *)
(* ================================================================ *)

let compose ops =
  let rec flatten acc = function
    | [] -> acc
    | Seq inner :: rest ->
        let acc = flatten acc inner in
        flatten acc rest
    | Keep_all :: rest -> flatten acc rest
    | Add [] :: rest -> flatten acc rest
    | Remove [] :: rest -> flatten acc rest
    | op :: rest -> flatten (op :: acc) rest
  in
  match List.rev (flatten [] ops) with
  | [] -> Keep_all
  | [ x ] -> x
  | many -> Seq many

(* ================================================================ *)
(* predicates                                                        *)
(* ================================================================ *)

let rec is_identity = function
  | Keep_all -> true
  | Add names -> normalize names = []
  | Remove names -> normalize names = []
  | Seq ops -> List.for_all is_identity ops
  | Clear_all | Replace_with _ | Intersect_with _ -> false

let rec is_irreversible = function
  | Clear_all | Replace_with _ | Intersect_with _ -> true
  | Keep_all | Add _ | Remove _ -> false
  | Seq ops -> List.exists is_irreversible ops

(* ================================================================ *)
(* serialization                                                     *)
(* ================================================================ *)

let names_to_json names =
  `List (List.map (fun n -> `String n) (normalize names))

let rec to_yojson = function
  | Keep_all -> `Assoc [("op", `String "keep_all")]
  | Clear_all -> `Assoc [("op", `String "clear_all")]
  | Add names -> `Assoc [("op", `String "add"); ("names", names_to_json names)]
  | Remove names -> `Assoc [("op", `String "remove"); ("names", names_to_json names)]
  | Replace_with names ->
      `Assoc [("op", `String "replace_with"); ("names", names_to_json names)]
  | Intersect_with names ->
      `Assoc [("op", `String "intersect_with"); ("names", names_to_json names)]
  | Seq ops ->
      `Assoc [("op", `String "seq"); ("ops", `List (List.map to_yojson ops))]

let inverse_result_to_yojson = function
  | Reversible op -> `Assoc [("reversible", to_yojson op)]
  | Irreversible -> `Assoc [("irreversible", `Bool true)]

(* ================================================================ *)
(* equal                                                             *)
(* ================================================================ *)

let sort_dedup names =
  names |> normalize |> List.sort String.compare

let rec equal a b =
  match (a, b) with
  | Keep_all, Keep_all -> true
  | Clear_all, Clear_all -> true
  | Add a_names, Add b_names -> sort_dedup a_names = sort_dedup b_names
  | Remove a_names, Remove b_names -> sort_dedup a_names = sort_dedup b_names
  | Replace_with a_names, Replace_with b_names ->
      sort_dedup a_names = sort_dedup b_names
  | Intersect_with a_names, Intersect_with b_names ->
      sort_dedup a_names = sort_dedup b_names
  | Seq a_ops, Seq b_ops ->
      List.compare_lengths a_ops b_ops = 0
      && List.for_all2 equal a_ops b_ops
  | _ -> false
