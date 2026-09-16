(** Keeper_model_input_ledger — see the interface for the contract. *)

type request =
  { prefix_digest : string
  ; first_atom : int
  ; atom_count : int
  ; tail_bytes : int
  }

type usage =
  { input_tokens : int
  ; cache_read_input_tokens : int
  }

type block =
  { block_first_atom : int
  ; block_end_atom : int
  ; tokens : int option
  }

type t =
  { prefix_digest : string
  ; total_tokens : int option
  ; measured_end_atom : int option
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
  | Prefix_changed
  | History_reset

type observation =
  { ledger : t
  ; event : event
  ; delta_tokens : int option
  ; tail_delta_bytes : int
  }

let base_block (request : request) =
  { block_first_atom = request.first_atom
  ; block_end_atom = request.atom_count
  ; tokens = None
  }
;;

(* A ledger that knows nothing but the request in hand. The whole carried
   range is one block of unknown size; the usage, when present, is the total
   the next difference will be taken against. *)
let start (request : request) (usage : usage option) =
  { prefix_digest = request.prefix_digest
  ; total_tokens = Option.map (fun (u : usage) -> u.input_tokens) usage
  ; measured_end_atom = Option.map (fun (_ : usage) -> request.atom_count) usage
  ; blocks = [ base_block request ]
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
        ; tokens = Some delta
        }
      ]
;;

let rec observe (previous : t option) (request : request) (usage : usage option)
  : observation
  =
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
  | Some t
    when request.atom_count < t.last.atom_count || request.first_atom < t.last.first_atom
    -> restart History_reset
  | Some t ->
    let evicted_atoms = request.first_atom - t.last.first_atom in
    (match trim_front t.blocks ~first_atom:request.first_atom with
     | `Cut -> restart (Front_cut_through_block { evicted_atoms })
     | `Trimmed (kept, evicted_tokens) ->
       observe_trimmed t request usage ~evicted_atoms ~kept ~evicted_tokens)

and observe_trimmed (t : t) (request : request) (usage : usage option)
      ~evicted_atoms ~kept ~evicted_tokens
  =
    let tail_delta_bytes = request.tail_bytes - t.last.tail_bytes in
    let new_atoms = request.atom_count - t.last.atom_count in
    let blocks =
      if new_atoms > 0
      then
        kept
        @ [ { block_first_atom = t.last.atom_count
            ; block_end_atom = request.atom_count
            ; tokens = None
            }
          ]
      else kept
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
    let blocks, measured =
      match delta_tokens, t.measured_end_atom with
      | Some delta, Some from_atom when new_atoms > 0 ->
        assign_tail blocks ~from_atom ~delta, true
      | Some _, (Some _ | None) | None, (Some _ | None) -> blocks, false
    in
    let total_tokens, measured_end_atom =
      match usage with
      | Some u -> Some u.input_tokens, Some request.atom_count
      | None ->
        (match previous_total, t.measured_end_atom with
         | Some total, Some at -> Some total, Some at
         | Some _, None | None, (Some _ | None) -> None, None)
    in
    let ledger =
      { prefix_digest = t.prefix_digest
      ; total_tokens
      ; measured_end_atom
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

let prefix_digest ~system_prompt ~tools =
  let schemas =
    List.map (fun tool -> Yojson.Safe.to_string (Agent_core.Tool.schema_to_json tool)) tools
  in
  Digestif.SHA256.(digest_string (String.concat "\n" (system_prompt :: schemas)) |> to_hex)
;;

module Table = struct
  module M = Map.Make (String)

  type state =
    { mutable ledgers : t M.t
    ; mutex : Eio.Mutex.t
    }

  let global = { ledgers = M.empty; mutex = Eio.Mutex.create () }
  let key ~keeper_name ~runtime_id = keeper_name ^ "\000" ^ runtime_id

  let observe ~keeper_name ~runtime_id ~request ~usage =
    let key = key ~keeper_name ~runtime_id in
    Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
      let observation = observe (M.find_opt key global.ledgers) request usage in
      global.ledgers <- M.add key observation.ledger global.ledgers;
      observation)
  ;;

  let lookup ~keeper_name ~runtime_id =
    Eio.Mutex.use_ro global.mutex (fun () ->
      M.find_opt (key ~keeper_name ~runtime_id) global.ledgers)
  ;;

  module For_testing = struct
    let reset () =
      Eio.Mutex.use_rw ~protect:true global.mutex (fun () -> global.ledgers <- M.empty)
    ;;
  end
end
