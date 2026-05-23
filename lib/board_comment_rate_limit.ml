(** Comment rate limiting: per-author sliding-window tracker.

    Extracted from [board_core.ml] (lines 60-90) as part of the godfile
    decomp campaign. Owns a single module-level [Hashtbl] keyed by
    author name, with each entry holding a mutable list of timestamps.

    The rate window and per-window limit come from [Limits]
    ([comment_rate_window_sec] / [comment_rate_limit]); when the limit
    is non-positive, [check] returns [None] (rate limiting disabled).

    Thread-safety: callers must hold [board_core] [with_lock store]
    before invoking [check] / [record]. The module itself uses
    [Stdlib.Hashtbl] (no internal locking). *)

module Hashtbl = Stdlib.Hashtbl
module List = Stdlib.List
module Limits = Board_types.Limits

let comment_timestamps : (string, float list ref) Hashtbl.t = Hashtbl.create 32

let check ~author ~now =
  let limit = Limits.comment_rate_limit in
  if limit <= 0 then None
  else
    let window = Float.of_int Limits.comment_rate_window_sec in
    match Hashtbl.find_opt comment_timestamps author with
    | None -> None
    | Some ts_ref ->
      let recent = List.filter (fun t -> now -. t < window) !ts_ref in
      ts_ref := recent;
      if List.length recent >= limit
      then
        let oldest = List.hd (List.sort Stdlib.compare recent) in
        let retry_after = window -. (now -. oldest) +. 1.0 in
        Some retry_after
      else None
;;

let record ~author ~now =
  let ts_ref =
    match Hashtbl.find_opt comment_timestamps author with
    | Some r -> r
    | None ->
      let r = ref [] in
      Hashtbl.replace comment_timestamps author r;
      r
  in
  ts_ref := now :: !ts_ref
;;

let reset () = Hashtbl.clear comment_timestamps

(** [sweep_stale ~now ~window] drops timestamps older than [window]
    seconds from every author's entry, then removes any author whose
    list became empty. Called from [board_core] [sweep] as part of the
    larger store sweep. *)
let sweep_stale ~now ~window =
  let stale_authors = ref [] in
  Hashtbl.iter
    (fun author ts_ref ->
       let recent = List.filter (fun t -> now -. t < window) !ts_ref in
       if List.length recent = 0 then stale_authors := author :: !stale_authors
       else ts_ref := recent)
    comment_timestamps;
  List.iter (Hashtbl.remove comment_timestamps) !stale_authors
;;
