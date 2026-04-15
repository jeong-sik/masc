(** Nickname generator for MASC agents - Docker-style adjective+animal *)

(* Adjectives - positive, memorable, easy to pronounce *)
let adjectives = [|
  "swift"; "brave"; "calm"; "eager"; "fierce";
  "gentle"; "happy"; "jolly"; "keen"; "lucky";
  "merry"; "noble"; "proud"; "quick"; "witty";
  "bold"; "cool"; "deft"; "fair"; "grand";
  "hale"; "jade"; "kind"; "lean"; "neat";
  "pale"; "rare"; "sage"; "tame"; "warm";
|]

(* Animals - recognizable, memorable *)
let animals = [|
  "fox"; "bear"; "wolf"; "hawk"; "lion";
  "tiger"; "eagle"; "otter"; "panda"; "koala";
  "raven"; "falcon"; "badger"; "beaver"; "whale";
  "shark"; "crane"; "heron"; "moose"; "viper";
  "cobra"; "gecko"; "lemur"; "llama"; "manta";
  "orca"; "rhino"; "sloth"; "tapir"; "zebra";
|]

(* RNG for nickname generation.  [Random.State.t] is NOT fiber-safe —
   the previous doc comment claiming otherwise was incorrect.  Guard
   the shared state with an [Eio.Mutex] and route every RNG access
   through [with_nickname_rng].  Same discipline as [Lib.A2a_tools]
   ([a2a_rng] / [a2a_rng_mutex]). *)
let nickname_rng = Random.State.make_self_init ()
let nickname_rng_mutex = Eio.Mutex.create ()
let with_nickname_rng f =
  Eio.Mutex.use_ro nickname_rng_mutex (fun () -> f nickname_rng)

(** Generate a short random suffix (4 hex chars) for uniqueness *)
let random_suffix () =
  Printf.sprintf "%04x"
    (with_nickname_rng (fun rng -> Random.State.int rng 0xFFFF))

(** Generate a unique nickname for an agent type.
    Format: {agent_type}-{adjective}-{animal}
    Example: claude-swift-fox, gemini-brave-tiger *)
let generate agent_type =
  let adj, animal =
    with_nickname_rng (fun rng ->
      ( adjectives.(Random.State.int rng (Array.length adjectives)),
        animals.(Random.State.int rng (Array.length animals)) ))
  in
  Printf.sprintf "%s-%s-%s" agent_type adj animal

(** Generate with suffix for guaranteed uniqueness.
    Format: {agent_type}-{adjective}-{animal}-{hex4}
    Example: claude-swift-fox-a3b2 *)
let generate_unique agent_type =
  let base = generate agent_type in
  Printf.sprintf "%s-%s" base (random_suffix ())

(** Check if a name looks like a generated nickname.
    Returns true for patterns like "claude-swift-fox" *)
let is_generated_nickname name =
  let parts = String.split_on_char '-' name in
  List.length parts >= 3

(** Extract agent_type from a generated nickname.
    "claude-swift-fox" -> Some "claude"
    "claude" -> Some "claude" (legacy) *)
let extract_agent_type name =
  let parts = String.split_on_char '-' name in
  match parts with
  | agent_type :: _ -> Some agent_type
  | [] -> None
