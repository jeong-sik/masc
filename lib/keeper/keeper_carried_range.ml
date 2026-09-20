(** Keeper_carried_range — see the interface for the contract. *)

type reason =
  | Total_unknown
  | Within_high_water
  | Nothing_evictable

type step =
  | Unchanged of reason
  | Evicted of
      { evicted_blocks : int
      ; evicted_atoms : int
      ; evicted_tokens : int option
      ; first_atom : int
      ; front_digest : string
      ; projected_total : int option
      }

(* Walk the blocks oldest first. [remaining] is the projected total while it
   is known. [stop] decides, on a known total, whether the walk has come down
   far enough; [at_least_one] forces the first eviction, as a provider
   refusal does, even when [stop] would already hold. The walk hands back the
   block it stopped at, so the caller never looks the survivor up again: the
   newest block is never consumed, and a list of two or more always stops at
   one. *)
type walked =
  { evicted_blocks : int
  ; evicted_atoms : int
  ; evicted_tokens : int option
  ; remaining : int option
  ; stopped_at : Keeper_model_input_ledger.block option
  }

let walk ~stop ~at_least_one ~(total : int option) (blocks : Keeper_model_input_ledger.block list)
  =
  let rec go ~evicted_blocks ~evicted_atoms ~evicted_tokens ~remaining = function
    | [] -> { evicted_blocks; evicted_atoms; evicted_tokens; remaining; stopped_at = None }
    | [ (last : Keeper_model_input_ledger.block) ] ->
      { evicted_blocks; evicted_atoms; evicted_tokens; remaining; stopped_at = Some last }
    | (b : Keeper_model_input_ledger.block) :: rest ->
      let forced = at_least_one && evicted_blocks = 0 in
      let done_ =
        match remaining with
        | Some r -> stop r && not forced
        | None ->
          (* No total to walk against: a refusal still takes one block. *)
          not forced
      in
      if done_
      then { evicted_blocks; evicted_atoms; evicted_tokens; remaining; stopped_at = Some b }
      else (
        let atoms = b.block_end_atom - b.block_first_atom in
        match b.tokens with
        | Some n ->
          go
            ~evicted_blocks:(evicted_blocks + 1)
            ~evicted_atoms:(evicted_atoms + atoms)
            ~evicted_tokens:(Option.map (fun t -> t + n) evicted_tokens)
            ~remaining:(Option.map (fun r -> r - n) remaining)
            rest
        | None ->
          (* Unknown size: it leaves whole, and nothing below it can be
             projected until the provider counts the next request. *)
          go
            ~evicted_blocks:(evicted_blocks + 1)
            ~evicted_atoms:(evicted_atoms + atoms)
            ~evicted_tokens:None
            ~remaining:None
            rest)
  in
  go ~evicted_blocks:0 ~evicted_atoms:0 ~evicted_tokens:(Some 0) ~remaining:total blocks
;;

let evict ~stop ~at_least_one (ledger : Keeper_model_input_ledger.t) =
  match ledger.blocks with
  | [] | [ _ ] -> Unchanged Nothing_evictable
  | blocks ->
    let w = walk ~stop ~at_least_one ~total:ledger.total_tokens blocks in
    (match w.stopped_at with
     | Some stopped_at when w.evicted_blocks > 0 ->
       Evicted
         { evicted_blocks = w.evicted_blocks
         ; evicted_atoms = w.evicted_atoms
         ; evicted_tokens = w.evicted_tokens
         ; first_atom = stopped_at.block_first_atom
         ; front_digest = stopped_at.block_first_digest
         ; projected_total = w.remaining
         }
     | Some _ | None -> Unchanged Nothing_evictable)
;;

let at_turn_boundary ~(marks : Runtime_schema.context_marks) (ledger : Keeper_model_input_ledger.t) =
  match ledger.total_tokens with
  | None -> Unchanged Total_unknown
  | Some total when total <= marks.high_water_tokens -> Unchanged Within_high_water
  | Some _ ->
    evict
      ~stop:(fun remaining -> remaining <= marks.low_water_tokens)
      ~at_least_one:false
      ledger
;;

let apply_turn_boundary ~(marks : Runtime_schema.context_marks) ledger =
  let step = at_turn_boundary ~marks ledger in
  match step with
  | Unchanged _ -> ledger, step
  | Evicted { first_atom; front_digest; _ } ->
    (match Keeper_model_input_ledger.move_front ledger ~first_atom ~front_digest with
     | Some moved -> moved, step
     | None ->
       invalid_arg
         "Keeper_carried_range.apply_turn_boundary: eviction did not advance the ledger")
;;

let after_overflow ~(marks : Runtime_schema.context_marks option) (ledger : Keeper_model_input_ledger.t) =
  match marks, ledger.total_tokens with
  | Some marks, Some _ ->
    evict
      ~stop:(fun remaining -> remaining <= marks.low_water_tokens)
      ~at_least_one:true
      ledger
  | Some _, None | None, (Some _ | None) ->
    (* One block: the refusal is the only measurement in hand. *)
    evict ~stop:(fun _ -> true) ~at_least_one:true ledger
;;

let reason_to_string = function
  | Total_unknown -> "total_unknown"
  | Within_high_water -> "within_high_water"
  | Nothing_evictable -> "nothing_evictable"
;;

let int_opt = function
  | Some n -> `Int n
  | None -> `Null
;;

let step_to_json = function
  | Unchanged reason -> `Assoc [ "step", `String "unchanged"; "reason", `String (reason_to_string reason) ]
  | Evicted
      { evicted_blocks
      ; evicted_atoms
      ; evicted_tokens
      ; first_atom
      ; front_digest = _
      ; projected_total
      } ->
    `Assoc
      [ "step", `String "evicted"
      ; "evicted_blocks", `Int evicted_blocks
      ; "evicted_atoms", `Int evicted_atoms
      ; "evicted_tokens", int_opt evicted_tokens
      ; "first_atom", `Int first_atom
      ; "projected_total", int_opt projected_total
      ]
;;
