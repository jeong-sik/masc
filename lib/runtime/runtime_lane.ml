(** Runtime lane — ordered list of candidate runtime ids for keeper turn routing.

    A lane is an opaque routing label (the lane id) plus an ordered candidate
    list of runtime ids.  When a keeper assignment resolves to a lane, the
    keeper turn driver resolves each id to a materialized {!Runtime_instance.t} and
    attempts them sequentially until one succeeds or the lane is exhausted.
    Keeping ids here breaks the [Runtime <-> Runtime_lane] module cycle. *)

type order =
  | Fixed
  | Spread_by_keeper
[@@deriving show, eq]

let order_to_string = function
  | Fixed -> "fixed"
  | Spread_by_keeper -> "spread_by_keeper"
;;

let order_of_string = function
  | "fixed" -> Some Fixed
  | "spread_by_keeper" -> Some Spread_by_keeper
  | _ -> None
;;

type t =
  { id : string
  ; candidates : string list
  ; order : order
  }

let make ?(order = Fixed) ~id candidates = { id; candidates; order }
let id t = t.id
let order t = t.order
let ordered_candidates t = t.candidates

let rotate_left ~offset items =
  match items with
  | [] | [ _ ] -> items
  | _ :: _ :: _ ->
    let len = List.length items in
    let shift = offset mod len in
    if shift = 0
    then items
    else
      let rec split n acc = function
        | rest when n <= 0 -> rest @ List.rev acc
        | [] -> List.rev acc
        | x :: xs -> split (n - 1) (x :: acc) xs
      in
      split shift [] items
;;

(* Deterministic cyclic starting offset for a Keeper sharing a multi-candidate
   lane. Uses the 16-bit big-endian prefix of the MD5 digest so placement is
   uniform, stable across restarts and architectures, and invariant to lane
   renames (preserving per-Keeper cache locality). *)
let spread_offset ~keeper_name ~count =
  let digest = Digest.string keeper_name in
  let prefix = (Char.code digest.[0] lsl 8) lor Char.code digest.[1] in
  prefix mod count
;;

let ordered_candidates_for ?keeper_name t =
  match t.order, keeper_name, t.candidates with
  | Fixed, _, candidates | Spread_by_keeper, None, candidates -> candidates
  | Spread_by_keeper, Some _, ([] | [ _ ] as candidates) -> candidates
  | Spread_by_keeper, Some name, (_ :: _ :: _ as candidates) ->
    let trimmed = String.trim name in
    if String.equal trimmed ""
    then candidates
    else
      let offset =
        spread_offset ~keeper_name:trimmed ~count:(List.length candidates)
      in
      rotate_left ~offset candidates
;;
