(* Keeper_turn_system — the System a keeper turn sends, and the articles that
   changed since it was rendered (RFC-0491 §3.2). See the mli. *)

type t =
  { text : string
  ; amendments : string option
  }

type basis =
  { articles : World_constitution_types.t list
  ; digest : string
  }

type front =
  | Same_front
  | Moved_front
  | No_previous_request

(* A range carries at least its newest atom, so the predicted first atom
   always has a message; [None] there names no position to compare. *)
let front ~digest_at ~first_atom ~(previous : Keeper_carried_front.seed option) =
  match previous, digest_at first_atom with
  | None, (Some _ | None) -> No_previous_request
  | Some previous, Some digest
    when previous.first_atom = first_atom
         && Model_input_front.equal previous.front (Model_input_front.At_atom digest) ->
    Same_front
  | Some _, (Some _ | None) -> Moved_front
;;

type decision =
  | From_basis of
      { text : string
      ; amendments : World_constitution_render.amendments option
      }
  | From_current of
      { text : string
      ; basis : basis
      }

let digest text = Agent_core_sha256.(digest_string text |> to_hex)

let decide ~front ~basis ~render ~current =
  let from_current () =
    let text = render current in
    From_current { text; basis = { articles = current; digest = digest text } }
  in
  match front, basis with
  | Same_front, Some basis ->
    let text = render basis.articles in
    if String.equal (digest text) basis.digest
    then
      From_basis
        { text
        ; amendments = World_constitution_render.amendments ~built_with:basis.articles current
        }
    else from_current ()
  | Same_front, None | (Moved_front | No_previous_request), (Some _ | None) -> from_current ()
;;

type lane =
  | Agent_core of front
  | Without_basis

(* One basis per base path and keeper, so two worlds in one process, and two
   tests with their own base paths, never read each other's. An immutable map
   behind [Atomic]: a read is one [Atomic.get], and [compare_and_set] installs
   a map only if no other domain replaced the one it was built from (stdlib
   atomic.mli), so a store retries only after another store landed. Two turns
   of one keeper deciding at once keep the later store, which costs at most
   one turn's cache. *)
module M = Map.Make (String)

let bases : basis M.t Atomic.t = Atomic.make M.empty
let key ~base_path ~keeper_name = base_path ^ "\000" ^ keeper_name

let rec store key basis =
  let seen = Atomic.get bases in
  if not (Atomic.compare_and_set bases seen (M.add key basis seen)) then store key basis
;;

let issue ~base_path ~keeper_name ~lane ~render ~current =
  match lane with
  | Without_basis -> { text = render current; amendments = None }
  | Agent_core front ->
    let key = key ~base_path ~keeper_name in
    (match decide ~front ~basis:(M.find_opt key (Atomic.get bases)) ~render ~current with
     | From_basis { text; amendments } ->
       { text; amendments = Option.map Keeper_prompt.constitution_amendments_block amendments }
     | From_current { text; basis } ->
       store key basis;
       { text; amendments = None })
;;

let with_bytes ~issued text =
  if String.equal issued.text text then issued else { text; amendments = None }
;;
