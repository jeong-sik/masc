(** Phantom-typed wrapper implementation for Keeper. *)

type offline
type running
type failing
type completed

type 'state t = {
  name : string;
}

let create ~name =
  { name }

let start (k : offline t) : running t =
  { name = k.name }

let run_turn (k : running t) =
  (* In a full implementation, this would delegate to Keeper_turn or Keeper_runtime.
     For now, we return Ok (success) as a placeholder. *)
  Ok { name = k.name }

let restart (k : failing t) : offline t =
  { name = k.name }

let stop (k : 'state t) : completed t =
  { name = k.name }

let name k = k.name
