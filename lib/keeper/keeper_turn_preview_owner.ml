type observed_turn = Unobserved | Exact of Ids.Turn_ref.t | Conflicting
type turn_observation = observed_turn Atomic.t
type binding = {interrupt_token : Keeper_interrupt_token.t; observation : turn_observation}
let key : binding Eio.Fiber.key = Eio.Fiber.create_key ()
let create_turn_observation () = Atomic.make Unobserved
let observed_turn_ref observation = match Atomic.get observation with
  | Exact turn_ref -> Some turn_ref | Unobserved | Conflicting -> None
let with_owner ~interrupt_token ~observation operation =
  Eio.Fiber.with_binding key {interrupt_token; observation} operation
let current_binding () = match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> None
  | Eio_fiber -> Eio.Fiber.get key
let current () = Option.map (fun binding -> binding.interrupt_token) (current_binding ())
let note_turn_ref turn_ref =
  Option.iter (fun binding ->
    let rec record () =
      let before = Atomic.get binding.observation in
      let replace after = if not (Atomic.compare_and_set binding.observation before after) then record () in
      match before with
      | Unobserved -> replace (Exact turn_ref)
      | Exact previous -> if not (Ids.Turn_ref.equal previous turn_ref) then replace Conflicting
      | Conflicting -> () in
    record ()) (current_binding ())
