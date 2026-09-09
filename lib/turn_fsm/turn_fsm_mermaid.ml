(** A Mermaid state diagram of the turn FSM, asked of the FSM rather than
    drawn beside it.

    Every node comes from [Turn_fsm.all_states] and every edge from
    [Turn_fsm.classify_transition], so the picture cannot disagree with the
    machine: a transition arm added or removed changes this output on the next
    call, with nothing to remember to update. A diagram kept in a document is
    a copy, and copies here have gone stale before.

    The text is the product, not a rendering of it. A browser renders it, a
    terminal can print it, and a model reading a keeper's state can be handed
    the same string. *)

let indent = "  "

(* Failed and Cancelled carry a reason and the FSM admits an edge per reason,
   so the raw pair scan yields six identical lines from every state into
   [failed] and six more into [cancelled] -- a hundred edges whose repetition
   carries nothing. What separates them is the action: [Runtime_routing]
   reaches [failed] as RuntimeUnavailable, NoToolCapableProvider,
   ProviderError or GenericFail, and those four are worth four lines. Six
   reasons that all classify as GenericFail are one edge drawn six times.

   So edges are folded on (from, to, action) and the reason is dropped. No
   distinction is lost: a reason the FSM treats differently already shows up
   as a different action, and one it treats the same is not a different
   edge. *)
let edges () =
  let seen = Hashtbl.create 64 in
  List.concat_map
    (fun from_any ->
      List.filter_map
        (fun to_any ->
          let (Turn_fsm.Any from_state) = from_any in
          let (Turn_fsm.Any to_state) = to_any in
          match Turn_fsm.classify_transition ~from_state ~to_state () with
          | None -> None
          | Some action ->
              let edge =
                ( Turn_fsm.to_tla_symbol from_state,
                  Turn_fsm.to_tla_symbol to_state,
                  Turn_fsm.transition_action_label action )
              in
              if Hashtbl.mem seen edge then None
              else (
                Hashtbl.add seen edge ();
                Some edge))
        Turn_fsm.all_states)
    Turn_fsm.all_states

let node_symbols () =
  List.sort_uniq String.compare
    (List.map Turn_fsm.any_state_symbol Turn_fsm.all_states)

(* [current] names the state the reader is standing in. It is matched against
   the symbol, not the label: a label carries the reason and would never match
   a caller holding "Streaming". An unknown name highlights nothing rather
   than inventing a node -- a diagram that grows a box for a typo is worse
   than one that simply does not light up. *)
let diagram ?current () =
  let buf = Buffer.create 2048 in
  let line s = Buffer.add_string buf (s ^ "\n") in
  line "stateDiagram-v2";
  (* The entry arrow points at the idle symbol the FSM reports, not a name
     spelled here. Writing "Idle" produced a second, empty node beside the
     real lowercase one -- the diagram drew a state the machine does not
     have. *)
  List.iter
    (fun sym -> line (Printf.sprintf "%s[*] --> %s" indent sym))
    Turn_fsm.idle_symbols;
  List.iter
    (fun (from_sym, to_sym, label) ->
      line (Printf.sprintf "%s%s --> %s: %s" indent from_sym to_sym label))
    (edges ());
  List.iter
    (fun sym ->
      if List.mem sym Turn_fsm.terminal_symbols then
        line (Printf.sprintf "%s%s --> [*]" indent sym))
    (node_symbols ());
  List.iter
    (fun sym ->
      let role =
        if List.mem sym Turn_fsm.terminal_symbols then Some "terminal"
        else if List.mem sym Turn_fsm.idle_symbols then Some "idle"
        else if List.mem sym Turn_fsm.active_symbols then Some "active"
        else None
      in
      match role with
      | None -> ()
      | Some role -> line (Printf.sprintf "%sclass %s %s" indent sym role))
    (node_symbols ());
  (* Compared without case. Symbols are lowercase and callers hold the
     constructor spelling ("Streaming"); an exact match highlights nothing
     and says nothing about why, which is the failure this whole diagram is
     meant to avoid. Symbols stay distinct without case, so folding it
     cannot light the wrong node. *)
  (match current with
   | None -> ()
   | Some current ->
       let wanted = String.lowercase_ascii current in
       List.iter
         (fun sym ->
           if String.equal (String.lowercase_ascii sym) wanted then
             line (Printf.sprintf "%sclass %s current" indent sym))
         (node_symbols ()));
  line (indent ^ "classDef idle fill:#2b2b2b,color:#ddd");
  line (indent ^ "classDef active fill:#1f3d5c,color:#fff");
  line (indent ^ "classDef terminal fill:#3d2b2b,color:#fff");
  line (indent ^ "classDef current stroke:#7fd67f,stroke-width:3px");
  Buffer.contents buf
