module Types = Keeper_memory_os_types
module Log = Librarian_log
module Log_store = Librarian_log_store
module By_id = Map.Make (String)

type left =
  { fact : Types.fact
  ; removal : Librarian_effects.removal
  ; at : float
  ; line_at : int
  }

type t =
  { left : left list
  ; unreadable : int
  }

(* What the scan has seen leave, each with the count of removals before it:
   the order they left in, across lines and within one. *)
type seen =
  { gone : (int * left) By_id.t
  ; removals : int
  ; unreadable : int
  }

(* The last line that names a fact decides: a removal keeps it, an addition
   takes it out again. *)
let after_commit seen ~line_at (commit : Log.commit) =
  let seen =
    List.fold_left
      (fun seen (fact, removal) ->
         { seen with
           gone =
             By_id.add (Types.memory_id fact)
               (seen.removals, { fact; removal; at = commit.at; line_at })
               seen.gone
         ; removals = seen.removals + 1
         })
      seen
      commit.effects.removed
  in
  { seen with
    gone =
      List.fold_left
        (fun gone fact -> By_id.remove (Types.memory_id fact) gone)
        seen.gone
        commit.effects.added
  }
;;

let read path ~current =
  let after seen ({ at; line } : Log_store.scanned) =
    match line with
    | Error (_ : Log_store.undecodable) -> { seen with unreadable = seen.unreadable + 1 }
    | Ok (Started _) -> seen
    | Ok (Committed commit) -> after_commit seen ~line_at:at commit
  in
  match
    Log_store.fold path ~init:{ gone = By_id.empty; removals = 0; unreadable = 0 } ~f:after
  with
  | Error _ as error -> error
  | Ok { gone; unreadable; removals = (_ : int) } ->
    let gone =
      List.fold_left (fun gone fact -> By_id.remove (Types.memory_id fact) gone) gone current
    in
    let in_order =
      List.sort (fun (a, (_ : left)) (b, (_ : left)) -> Int.compare a b)
        (List.map snd (By_id.bindings gone))
    in
    Ok { left = List.map snd in_order; unreadable }
;;
