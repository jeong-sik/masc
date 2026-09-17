(** Keeper_model_input_ledger — see the interface for the contract. *)

type carried_ends =
  | No_atom_carried
  | Carried_atoms of
      { front_digest : string
      ; end_digest : string
      }

type request =
  { prefix_digest : string
  ; first_atom : int
  ; atom_count : int
  ; ends : carried_ends
  ; tail_bytes : int
  ; turn_context : bool
  ; demote_before : int
  }

type usage =
  { input_tokens : int
  ; cache_read_input_tokens : int
  }

type block =
  { block_first_atom : int
  ; block_end_atom : int
  ; block_first_digest : string
  ; tokens : int option
  }

type t =
  { prefix_digest : string
  ; total_tokens : int option
  ; measured_end_atom : int option
  ; measured_demote_before : int option
  ; blocks : block list
  ; last : request
  ; last_usage : usage option
  }

type event =
  | Started
  | Appended of
      { new_atoms : int
      ; measured : bool
      }
  | Repeated
  | Front_moved of
      { evicted_atoms : int
      ; evicted_tokens : int option
      }
  | Front_cut_through_block of { evicted_atoms : int }
  | Front_widened
  | Prefix_changed
  | History_reset

type observation =
  { ledger : t
  ; event : event
  ; delta_tokens : int option
  ; tail_delta_bytes : int
  }

(* The carried range of a request as one block of unknown size, opened by the
   request's own front message. A request that carried no atom has no range
   and no block. *)
let base_blocks (request : request) =
  match request.ends with
  | No_atom_carried -> []
  | Carried_atoms { front_digest; end_digest = _ } ->
    [ { block_first_atom = request.first_atom
      ; block_end_atom = request.atom_count
      ; block_first_digest = front_digest
      ; tokens = None
      }
    ]
;;

(* A ledger that knows nothing but the request in hand. The whole carried
   range is one block of unknown size; the usage, when present, is the total
   the next difference will be taken against. *)
let start (request : request) (usage : usage option) =
  { prefix_digest = request.prefix_digest
  ; total_tokens = Option.map (fun (u : usage) -> u.input_tokens) usage
  ; measured_end_atom = Option.map (fun (_ : usage) -> request.atom_count) usage
  ; measured_demote_before = Option.map (fun (_ : usage) -> request.demote_before) usage
  ; blocks = base_blocks request
  ; last = request
  ; last_usage = usage
  }
;;

(* Remove every block below [first_atom]. The evicted tokens are known only
   when every removed block was measured. A front that falls inside a block
   is reported as [`Cut]: the part that left is unmeasured and so is the part
   that stayed, and nothing downstream can be attributed any more. *)
let trim_front blocks ~first_atom =
  let rec go acc evicted_tokens = function
    | [] -> `Trimmed (List.rev acc, evicted_tokens)
    | b :: rest when b.block_end_atom <= first_atom ->
      let evicted_tokens =
        match evicted_tokens, b.tokens with
        | Some sum, Some tokens -> Some (sum + tokens)
        | Some _, None | None, (Some _ | None) -> None
      in
      go acc evicted_tokens rest
    | b :: _ when b.block_first_atom < first_atom -> `Cut
    | b :: rest -> go (b :: acc) evicted_tokens rest
  in
  go [] (Some 0) blocks
;;

(* Assign [delta] to the blocks between [measured_end_atom] and the end of the
   carried range, merged into one, so a stretch of usage-less requests is
   measured as a single block when usage returns. *)
let assign_tail blocks ~from_atom ~delta =
  let before, after =
    List.partition (fun b -> b.block_end_atom <= from_atom) blocks
  in
  match after with
  | [] -> blocks
  | first :: _ ->
    let last = List.nth after (List.length after - 1) in
    before
    @ [ { block_first_atom = first.block_first_atom
        ; block_end_atom = last.block_end_atom
        ; block_first_digest = first.block_first_digest
        ; tokens = Some delta
        }
      ]
;;

(* The demotion boundary moved between the sample the total describes and
   this one, so the atoms from [changed_from] on are carried in another form
   than they were measured in. Those blocks and the atoms appended since the
   sample become one block. The difference is exactly the appended atoms plus
   the change of the reformed ones, so adding back what the reformed blocks
   weighed leaves what they and the appended atoms weigh now. Unknown when a
   reformed block was never measured. *)
let merge_reformed blocks ~changed_from ~measured_end ~delta =
  let before, after = List.partition (fun b -> b.block_end_atom <= changed_from) blocks in
  match after with
  | [] -> blocks, false
  | first :: _ ->
    let last = List.nth after (List.length after - 1) in
    (* Blocks past [measured_end] are the appended atoms [delta] measures. *)
    let reformed = List.filter (fun b -> b.block_first_atom < measured_end) after in
    let weighed =
      List.fold_left
        (fun sum b ->
           match sum, b.tokens with
           | Some total, Some tokens -> Some (total + tokens)
           | Some _, None | None, (Some _ | None) -> None)
        (Some 0)
        reformed
    in
    let tokens =
      match weighed with
      | Some old when old + delta >= 0 -> Some (old + delta)
      | Some _ | None -> None
    in
    ( before
      @ [ { block_first_atom = first.block_first_atom
          ; block_end_atom = last.block_end_atom
          ; block_first_digest = first.block_first_digest
          ; tokens
          }
        ]
    , Option.is_some tokens )
;;

(* Whether the history in hand still opens [atom] with the message the ledger
   recorded there. An index the history no longer has does not hold. *)
let position_holds ~digest_at ~atom recorded =
  match digest_at atom with
  | Some found -> String.equal found recorded
  | None -> false
;;

(* The atoms the ledger counted are the ones in this history only while the
   front and the last atom of the last request still open with the messages
   that request carried. A shorter history misses the last index; a purge
   before the front, or an unsaved attempt's atom replaced by another at the
   same index, changes a digest. Nothing here can prove the atoms between the
   two, so no rule keeps part of the blocks after either check fails. A
   request that carried no atom named no position, and nothing it counted
   can have moved. *)
let history_holds ~digest_at (last : request) =
  match last.ends with
  | No_atom_carried -> true
  | Carried_atoms { front_digest; end_digest } ->
    position_holds ~digest_at ~atom:last.first_atom front_digest
    && position_holds ~digest_at ~atom:(last.atom_count - 1) end_digest
;;

let observe_trimmed
      (t : t)
      (request : request)
      (usage : usage option)
      ~evicted_atoms
      ~kept
      ~evicted_tokens
      ~(appended : block option)
  =
    let tail_delta_bytes = request.tail_bytes - t.last.tail_bytes in
    let new_atoms, blocks =
      match appended with
      | Some block -> block.block_end_atom - block.block_first_atom, kept @ [ block ]
      | None -> 0, kept
    in
    (* The previous total still describes the carried atoms only when the
       atoms that left it were measured. *)
    let previous_total =
      match t.total_tokens, evicted_tokens with
      | Some total, Some evicted -> Some (total - evicted)
      | Some _, None | None, (Some _ | None) -> None
    in
    let delta_tokens =
      match usage, previous_total with
      | Some u, Some total -> Some (u.input_tokens - total)
      | Some _, None | None, (Some _ | None) -> None
    in
    let reformed_from =
      match t.measured_demote_before with
      | Some before when before <> request.demote_before ->
        Some (min before request.demote_before)
      | Some _ | None -> None
    in
    (* A negative difference with no reformed atoms is reported but not
       written into a block. *)
    let blocks, measured =
      match delta_tokens, t.measured_end_atom, reformed_from with
      | Some delta, Some measured_end, Some changed_from ->
        merge_reformed blocks ~changed_from ~measured_end ~delta
      | Some delta, Some from_atom, None when new_atoms > 0 && delta >= 0 ->
        assign_tail blocks ~from_atom ~delta, true
      | Some _, Some _, None | Some _, None, (Some _ | None) | None, (Some _ | None), (Some _ | None)
        -> blocks, false
    in
    let total_tokens, measured_end_atom, measured_demote_before =
      match usage with
      | Some u -> Some u.input_tokens, Some request.atom_count, Some request.demote_before
      | None ->
        (match previous_total, t.measured_end_atom with
         | Some total, Some at -> Some total, Some at, t.measured_demote_before
         | Some _, None | None, (Some _ | None) -> None, None, None)
    in
    let ledger =
      { prefix_digest = t.prefix_digest
      ; total_tokens
      ; measured_end_atom
      ; measured_demote_before
      ; blocks
      ; last = request
      ; last_usage = (match usage with Some _ -> usage | None -> t.last_usage)
      }
    in
    let event =
      if evicted_atoms > 0
      then Front_moved { evicted_atoms; evicted_tokens }
      else if new_atoms > 0
      then Appended { new_atoms; measured }
      else Repeated
    in
    { ledger; event; delta_tokens; tail_delta_bytes }
;;

let observe ~digest_at (previous : t option) (request : request) (usage : usage option)
  : observation
  =
  (* The turn context's tokens belong to no atom, so a request that carried
     it is read like one without usage: its atoms wait for the next sample. *)
  let usage = if request.turn_context then None else usage in
  let restart event =
    { ledger = start request usage
    ; event
    ; delta_tokens = None
    ; tail_delta_bytes =
        (match previous with
         | Some t -> request.tail_bytes - t.last.tail_bytes
         | None -> 0)
    }
  in
  match previous with
  | None -> restart Started
  | Some t when request.prefix_digest <> t.prefix_digest -> restart Prefix_changed
  | Some t when not (history_holds ~digest_at t.last) -> restart History_reset
  | Some t when request.first_atom < t.last.first_atom -> restart Front_widened
  | Some t ->
    let evicted_atoms = request.first_atom - t.last.first_atom in
    (match trim_front t.blocks ~first_atom:request.first_atom with
     | `Cut -> restart (Front_cut_through_block { evicted_atoms })
     | `Trimmed (kept, evicted_tokens) ->
       (* Atoms carried for the first time. A front that moved past everything
          previously carried starts the new block at the front, not at the
          old end: the atoms in between were never on the wire. The block is
          named by the message that opens its first atom in this history; a
          history that has no atom there is not the one the request counted. *)
       let new_block_start = max t.last.atom_count request.first_atom in
       if request.atom_count <= new_block_start
       then
         observe_trimmed t request usage ~evicted_atoms ~kept ~evicted_tokens ~appended:None
       else (
         match digest_at new_block_start with
         | None -> restart History_reset
         | Some block_first_digest ->
           observe_trimmed
             t
             request
             usage
             ~evicted_atoms
             ~kept
             ~evicted_tokens
             ~appended:
               (Some
                  { block_first_atom = new_block_start
                  ; block_end_atom = request.atom_count
                  ; block_first_digest
                  ; tokens = None
                  })))
;;

let holds ~digest_at (t : t) = history_holds ~digest_at t.last

(* Apply an eviction the carried range decided: the same trimming a request
   would report as [Front_moved], applied now so the next composition (the
   turn's first, or a refusal retry) sees the moved front. A front inside a
   block restarts the blocks from the new front with the total unknown, as
   [observe] would. The moved front is recorded with the message that opens
   it, so the next composition and the next [observe] check the position
   they compose from; the last atom's digest stays the last request's.

   [None] when nothing moves, so a caller that retries on a move never asks
   again with the front it already had: a front at or behind the current one,
   a front at or past the last request's atom count (there is no atom there to
   carry from), or a ledger whose last request carried no atom and so has no
   front. *)
let move_front (t : t) ~first_atom ~front_digest =
  match t.last.ends with
  | No_atom_carried -> None
  | Carried_atoms { front_digest = _; end_digest }
    when first_atom > t.last.first_atom && first_atom < t.last.atom_count ->
    let last =
      { t.last with first_atom; ends = Carried_atoms { front_digest; end_digest } }
    in
    (match trim_front t.blocks ~first_atom with
     | `Cut ->
       Some
         { t with
           total_tokens = None
         ; measured_end_atom = None
         ; measured_demote_before = None
         ; blocks = base_blocks last
         ; last
         }
     | `Trimmed (kept, evicted_tokens) ->
       let total_tokens, measured_end_atom, measured_demote_before =
         match t.total_tokens, evicted_tokens with
         | Some total, Some evicted ->
           Some (total - evicted), t.measured_end_atom, t.measured_demote_before
         | Some _, None | None, (Some _ | None) -> None, None, None
       in
       Some
         { t with total_tokens; measured_end_atom; measured_demote_before; blocks = kept; last })
  | Carried_atoms _ -> None
;;

let known_tokens t =
  List.fold_left
    (fun sum b -> match b.tokens with Some n -> sum + n | None -> sum)
    0
    t.blocks
;;

let unmeasured_atoms t =
  List.fold_left
    (fun sum b ->
       match b.tokens with
       | Some _ -> sum
       | None -> sum + (b.block_end_atom - b.block_first_atom))
    0
    t.blocks
;;

let event_to_string = function
  | Started -> "started"
  | Appended { measured = true; _ } -> "appended_measured"
  | Appended { measured = false; _ } -> "appended_unmeasured"
  | Repeated -> "repeated"
  | Front_moved { evicted_tokens = Some _; _ } -> "front_moved_measured"
  | Front_moved { evicted_tokens = None; _ } -> "front_moved_unmeasured"
  | Front_cut_through_block _ -> "front_cut_through_block"
  | Front_widened -> "front_widened"
  | Prefix_changed -> "prefix_changed"
  | History_reset -> "history_reset"
;;

let int_opt = function
  | Some n -> `Int n
  | None -> `Null
;;

let block_to_json b =
  `Assoc
    [ "first_atom", `Int b.block_first_atom
    ; "end_atom", `Int b.block_end_atom
    ; "tokens", int_opt b.tokens
    ]
;;

let to_json t =
  `Assoc
    [ "prefix_digest", `String t.prefix_digest
    ; "total_tokens", int_opt t.total_tokens
    ; "measured_end_atom", int_opt t.measured_end_atom
    ; "known_tokens", `Int (known_tokens t)
    ; "unmeasured_atoms", `Int (unmeasured_atoms t)
    ; "first_atom", `Int t.last.first_atom
    ; "atom_count", `Int t.last.atom_count
    ; "tail_bytes", `Int t.last.tail_bytes
    ; "turn_context", `Bool t.last.turn_context
    ; "demote_before", `Int t.last.demote_before
    ; "blocks", `Int (List.length t.blocks)
    ; ( "measured_blocks"
      , `Int (List.length (List.filter (fun b -> Option.is_some b.tokens) t.blocks)) )
    ; ( "cache_read_input_tokens"
      , int_opt (Option.map (fun (u : usage) -> u.cache_read_input_tokens) t.last_usage) )
    ]
;;

let blocks_to_json t = `List (List.map block_to_json t.blocks)

let observation_to_json o =
  `Assoc
    [ "event", `String (event_to_string o.event)
    ; "delta_tokens", int_opt o.delta_tokens
    ; "tail_delta_bytes", `Int o.tail_delta_bytes
    ; "ledger", to_json o.ledger
    ]
;;

let usage_of_counts ~input_tokens ~cache_read_input_tokens =
  if input_tokens > 0 then Some { input_tokens; cache_read_input_tokens } else None
;;

(* Length-prefixed parts, so a prompt that happens to end in a schema's text
   cannot digest like the prompt plus that schema. *)
let prefix_digest ~system_prompt ~tools =
  let part text = Printf.sprintf "%d:%s" (String.length text) text in
  let schemas =
    List.map
      (fun tool -> part (Yojson.Safe.to_string (Agent_core.Tool.schema_to_json tool)))
      tools
  in
  Digestif.SHA256.(digest_string (String.concat "" (part system_prompt :: schemas)) |> to_hex)
;;

module Table = struct
  module M = Map.Make (String)

  type state =
    { mutable ledgers : t M.t
    ; mutex : Eio.Mutex.t
    }

  let global = { ledgers = M.empty; mutex = Eio.Mutex.create () }
  (* One ledger per history: the session names the checkpoint the atoms
     are positions in, so a recovery worker's turn on the same keeper and
     runtime, or a new session, never reads or writes another's front. *)
  let key ~keeper_name ~runtime_id ~session_id =
    keeper_name ^ "\000" ^ runtime_id ^ "\000" ^ session_id
  ;;

  let observe ~keeper_name ~runtime_id ~session_id ~digest_at ~request ~usage =
    let key = key ~keeper_name ~runtime_id ~session_id in
    Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
      let observation = observe ~digest_at (M.find_opt key global.ledgers) request usage in
      global.ledgers <- M.add key observation.ledger global.ledgers;
      observation)
  ;;

  let lookup ~keeper_name ~runtime_id ~session_id =
    Eio.Mutex.use_ro global.mutex (fun () ->
      M.find_opt (key ~keeper_name ~runtime_id ~session_id) global.ledgers)
  ;;

  type in_history =
    | Holds of t
    | Dropped_stale of t
    | Absent

  (* The digests are read outside the lock; the removal happens only if the
     ledger that failed the check is still the pair's, so a ledger another
     observation wrote in between is not the one dropped. *)
  let lookup_in_history ~keeper_name ~runtime_id ~session_id ~digest_at =
    match lookup ~keeper_name ~runtime_id ~session_id with
    | None -> Absent
    | Some t when holds ~digest_at t -> Holds t
    | Some stale ->
      let key = key ~keeper_name ~runtime_id ~session_id in
      Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
        match M.find_opt key global.ledgers with
        | Some current when current == stale -> global.ledgers <- M.remove key global.ledgers
        | Some _ | None -> ());
      Dropped_stale stale
  ;;

  type move =
    | Moved
    | Not_moved
    | No_pair_ledger

  (* [move_front] in the body is the ledger function above: this binding is
     not recursive. *)
  let move_front ~keeper_name ~runtime_id ~session_id ~first_atom ~front_digest =
    let key = key ~keeper_name ~runtime_id ~session_id in
    Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
      match M.find_opt key global.ledgers with
      | None -> No_pair_ledger
      | Some t ->
        (match move_front t ~first_atom ~front_digest with
         | Some moved ->
           global.ledgers <- M.add key moved global.ledgers;
           Moved
         | None -> Not_moved))
  ;;

  module For_testing = struct
    let reset () =
      Eio.Mutex.use_rw ~protect:true global.mutex (fun () -> global.ledgers <- M.empty)
    ;;
  end
end
