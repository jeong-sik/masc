(** Process-local registry of currently-unreadable keeper stores.

    Consumed by [dashboard_execution] to expose on the "주의 필요" card.
    Populated by [Keeper_meta_store.Problem_report_state] when meta
    files fail to decode.

    Growth bound: O(failing keepers) — one entry per (site, path)
    that currently fails.  Cleared on recovery or config removal. *)

type entry = {
  site : string;
  path : string;
  detail : string;
  first_observed : float;
}

module Key = struct
  type t = string * string
  let equal (a, b) (c, d) = String.equal a c && String.equal b d
  let hash = Hashtbl.hash
end

module Table = Hashtbl.Make (Key)

let table : (string * float) Table.t = Table.create 16
let mutex = Stdlib.Mutex.create ()

let register ~site ~path ~detail =
  Stdlib.Mutex.protect mutex (fun () ->
    let key = (site, path) in
    match Table.find_opt table key with
    | Some (prev, first_observed) when String.equal prev detail -> false
    | Some (_, first_observed) ->
        Table.replace table key (detail, first_observed);
        true
    | None ->
        Table.replace table key (detail, Unix.gettimeofday ());
        true)
;;

let clear ~site ~path =
  Stdlib.Mutex.protect mutex (fun () ->
    Table.remove table (site, path))
;;

let snapshot () =
  Stdlib.Mutex.protect mutex (fun () ->
    Table.fold
      (fun (site, path) (detail, first_observed) acc ->
        { site; path; detail; first_observed } :: acc)
      table
      [])
;;

let entry_to_yojson (e : entry) =
  `Assoc [
    ("site", `String e.site);
    ("path", `String e.path);
    ("detail", `String e.detail);
    ("first_observed", `Float e.first_observed);
  ]
;;

let snapshot_to_yojson () =
  `List (List.map entry_to_yojson (snapshot ()))
;;

let reset () =
  Stdlib.Mutex.protect mutex (fun () ->
    Table.clear table)
;;
