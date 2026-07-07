(** Keeper_recall_injection_window — see the interface for the contract. *)

let window_turns = 32

type entry =
  { turn : int
  ; keys : string list
  }

(* Guarded by [mu]. Keyed by keeper_id; each list is newest-first and bounded
   by the prune in [note] (at most [window_turns] entries per keeper). *)
let mu = Stdlib.Mutex.create ()
let table : (string, entry list) Hashtbl.t = Hashtbl.create 16

let note ~keeper_id ~turn ~keys =
  match keys with
  | [] -> ()
  | _ ->
    Stdlib.Mutex.protect mu (fun () ->
      let prior =
        Option.value (Hashtbl.find_opt table keeper_id) ~default:[]
      in
      let kept =
        List.filter
          (fun entry -> entry.turn < turn && turn - entry.turn < window_turns)
          prior
      in
      Hashtbl.replace table keeper_id ({ turn; keys } :: kept))
;;

let recently_injected ~keeper_id ~key =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt table keeper_id with
    | None -> false
    | Some entries ->
      List.exists (fun entry -> List.exists (String.equal key) entry.keys) entries)
;;
