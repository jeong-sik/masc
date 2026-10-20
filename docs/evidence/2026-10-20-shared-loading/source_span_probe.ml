module Agent_core = struct
 module Types = struct
  type role = System | User | Assistant | Tool
  type message = {role:role; id:int; pinned:bool}
 end
 module Checkpoint = struct
  let message_to_json (m:Types.message) = `Assoc ["id",`Int m.id]
 end
end
module Ids = struct module Turn_ref = struct
 type t=string * int
 let trace_id = fst
 end end
module Keeper_turn_task_context = struct type t = No_task | Task of int end
module Keeper_turn_boundaries = struct
 type position = {end_atom:int;last_atom_digest:string}
 type history = Fresh_history | Continued_history | Continued_history_from of {start_atom:int;start_atom_digest:string}
 type state = Atom_history of position | Empty_atom_history | No_atom_history | Stale_noop
 type event = Turn_ended of {turn_ref:Ids.Turn_ref.t;task_context:Keeper_turn_task_context.t;history_at_start:history;position:state} | History_restarted of {trace_id:string}
 type record = {event:event;recorded_at:float}
end
module B=Keeper_turn_boundaries
module Runtime_model_input_tail_window = struct
 let is_pinned (m:Agent_core.Types.message)=m.pinned
 type label= Pinned | Atom of int
let annotate (messages : Agent_core.Types.message list) :
  (Agent_core.Types.message * label) list * int
  =
  let labelled_rev, atom_count =
    List.fold_left
      (fun (acc, count) (msg : Agent_core.Types.message) ->
         if is_pinned msg
         then ((msg, Pinned) :: acc, count)
         else (
           match msg.role with
           | Agent_core.Types.System -> ((msg, Pinned) :: acc, count)
           | Agent_core.Types.User | Agent_core.Types.Assistant ->
             ((msg, Atom count) :: acc, count + 1)
           | Agent_core.Types.Tool ->
             if count = 0
             then ((msg, Atom 0) :: acc, 1)
             else ((msg, Atom (count - 1)) :: acc, count)))
      ([], 0)
      messages
  in
  (List.rev labelled_rev, atom_count)
;;

(* The atom's position is its index plus the message that opens it: the
   first message [annotate] labels with that index, a [User] or [Assistant]
   message (or the orphan [Tool] that heads a history cut upstream). A [Tool]
   message that joins the atom later carries an index the atom already has,
   so it never becomes the opener. The digest is over the checkpoint
   encoding of that one message, the bytes a save writes for it.

   Partial application does the labelling once; each lookup encodes and
   hashes one message. *)
let atom_opening_digest (messages : Agent_core.Types.message list) =
  let labelled, _atom_count = annotate messages in
  let openers_rev, _next =
    List.fold_left
      (fun (openers, next) (message, label) ->
         match label with
         | Atom index when index = next -> message :: openers, next + 1
         | Atom _ | Pinned -> openers, next)
      ([], 0)
      labelled
  in
  let openers = Array.of_list (List.rev openers_rev) in
  fun atom ->
    if atom < 0 || atom >= Array.length openers
    then None
    else (
      let encoded =
        Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json openers.(atom))
      in
      Some Digestif.SHA256.(digest_string encoded |> to_hex))
;;

end
module W=Runtime_model_input_tail_window
module R = struct
 module Window=W
 type range={start_atom:int;end_atom:int;history_start_boundary_line:int}
 type atom_cut={cut_line:int;cut_end_atom:int}
let slice messages (range : range) =
  let labelled, _atom_count = Window.annotate messages in
  List.filter_map
    (fun (message, label) ->
       match label with
       | Window.Atom atom ->
         if atom >= range.start_atom && atom < range.end_atom then Some message else None
       | Window.Pinned -> None)
    labelled
;;

end
module Keeper_librarian_unread = struct
 type source = Atom of {trace_id:string;history_start_boundary_line:int;atom:int;message_in_atom:int;message_sha256:string} | Official_turn of int
 type t={source:source;reasons:string list}
 let message_digest m = Digestif.SHA256.(digest_string (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json m)) |> to_hex)
end
module U=Keeper_librarian_unread
 type prepared={trace_id:string;messages:Agent_core.Types.message list;lines:(int*(B.record,string) result)list;cuts:R.atom_cut list;range:R.range;start_atom:int;end_atom:int;previous_unread_messages:U.t list}
module H_before = struct
module B = Keeper_turn_boundaries
module Window = Runtime_model_input_tail_window

type source =
  | Atom_span of { trace_id : string; start_atom : int; end_atom : int }
  | Official_turn
  | Boundary_only

type attribution =
  | Observed of { turn_ref : Ids.Turn_ref.t; task_context : Keeper_turn_task_context.t }
  | Unattributed

type scope = { source : source; attribution : attribution }
type t = { scope : scope; first_message : int; after_message : int;
  first_tool_observation : int; after_tool_observation : int }

let atom_spans ~trace_id ~messages ~start_atom ~end_atom ~boundary =
  let span attribution start_atom end_atom =
    {source=Atom_span {trace_id;start_atom;end_atom};attribution} in
  let gap start_atom end_atom =
    if start_atom < end_atom then [span Unattributed start_atom end_atom] else [] in
  match boundary with
  | Some { B.event = B.Turn_ended {turn_ref;task_context;history_at_start;
      position=B.Atom_history position}; _ }
    when String.equal trace_id (Ids.Turn_ref.trace_id turn_ref)
      && end_atom <= position.end_atom
      && Window.atom_opening_digest messages (position.end_atom - 1)
         = Some position.last_atom_digest ->
    let attribution = Observed {turn_ref;task_context} in
    let admitted_start = match history_at_start with
      | B.Fresh_history -> Some 0
      | B.Continued_history -> None
      | B.Continued_history_from {start_atom;start_atom_digest} ->
        if start_atom > 0 && start_atom <= position.end_atom
           && Window.atom_opening_digest messages (start_atom - 1) = Some start_atom_digest
        then Some start_atom else None in
    (match admitted_start with
     | Some admitted_start ->
       let known_start = max start_atom admitted_start in
       gap start_atom (min end_atom known_start)
       @ (if known_start < end_atom then [span attribution known_start end_atom] else [])
     | None -> gap start_atom end_atom @ [{source=Boundary_only;attribution}])
  | Some
      { B.event =
          B.Turn_ended
            { position =
                (B.Atom_history _ | B.Empty_atom_history | B.No_atom_history | B.Stale_noop)
            ; _
            }
      ; _
      }
  | Some { B.event = B.History_restarted _; _ }
  | None -> gap start_atom end_atom

end
let before ?(include_unread=true) prepared =
  let module H = H_before in
  (* These cuts were validated against this immutable source during prepare.
     Keep the full list: a selected prefix can stop inside a completed turn. *)
  let cuts = prepared.cuts in
  let _, reversed = List.fold_left (fun (start_atom, reversed) (cut : R.atom_cut) ->
    let end_atom = min prepared.end_atom cut.cut_end_atom in
    if end_atom <= start_atom then start_atom, reversed else
    let boundary = match List.assoc_opt cut.cut_line prepared.lines with
      | Some (Ok boundary) -> Some boundary | Some (Error _) | None -> None in
    let scopes = H.atom_spans ~trace_id:prepared.trace_id ~messages:prepared.messages
      ~start_atom ~end_atom ~boundary in
    let spans = List.map (fun scope ->
      let messages = match scope.H.source with
        | H.Atom_span {start_atom;end_atom;_} ->
          let selected = R.slice prepared.messages {prepared.range with R.start_atom;end_atom} in
          if include_unread then selected else
          let labelled, _ = W.annotate prepared.messages in
          let _, _, retained = List.fold_left (fun (last_atom, next_position, retained) (message,label) ->
            match label with
            | W.Pinned -> last_atom, next_position, retained
            | W.Atom atom ->
              let position = if last_atom=Some atom then next_position else 0 in
              let omitted = List.exists (fun (hole : Keeper_librarian_unread.t) ->
                match hole.source with
                | Keeper_librarian_unread.Atom source ->
                  source.trace_id=prepared.trace_id
                  && source.history_start_boundary_line=prepared.range.history_start_boundary_line
                  && source.atom=atom && source.message_in_atom=position
                  && source.message_sha256=Keeper_librarian_unread.message_digest message
                | Keeper_librarian_unread.Official_turn _ -> false) prepared.previous_unread_messages in
              Some atom, position+1, if atom >= start_atom && atom < end_atom && not omitted
                then message :: retained else retained) (None,0,[]) labelled in
          List.rev retained
        | H.Boundary_only | H.Official_turn -> [] in
      scope, messages) scopes in
    end_atom, List.rev_append spans reversed)
    (prepared.start_atom, []) cuts in
  List.rev reversed

module H_after = struct
module B = Keeper_turn_boundaries

type source =
  | Atom_span of { trace_id : string; start_atom : int; end_atom : int }
  | Official_turn
  | Boundary_only

type attribution =
  | Observed of { turn_ref : Ids.Turn_ref.t; task_context : Keeper_turn_task_context.t }
  | Unattributed

type scope = { source : source; attribution : attribution }
type t = { scope : scope; first_message : int; after_message : int;
  first_tool_observation : int; after_tool_observation : int }

let atom_spans ~trace_id ~digest_at ~start_atom ~end_atom ~boundary =
  let span attribution start_atom end_atom =
    {source=Atom_span {trace_id;start_atom;end_atom};attribution} in
  let gap start_atom end_atom =
    if start_atom < end_atom then [span Unattributed start_atom end_atom] else [] in
  match boundary with
  | Some { B.event = B.Turn_ended {turn_ref;task_context;history_at_start;
      position=B.Atom_history position}; _ }
    when String.equal trace_id (Ids.Turn_ref.trace_id turn_ref)
      && end_atom <= position.end_atom
      && digest_at (position.end_atom - 1)
         = Some position.last_atom_digest ->
    let attribution = Observed {turn_ref;task_context} in
    let admitted_start = match history_at_start with
      | B.Fresh_history -> Some 0
      | B.Continued_history -> None
      | B.Continued_history_from {start_atom;start_atom_digest} ->
        if start_atom > 0 && start_atom <= position.end_atom
           && digest_at (start_atom - 1) = Some start_atom_digest
        then Some start_atom else None in
    (match admitted_start with
     | Some admitted_start ->
       let known_start = max start_atom admitted_start in
       gap start_atom (min end_atom known_start)
       @ (if known_start < end_atom then [span attribution known_start end_atom] else [])
     | None -> gap start_atom end_atom @ [{source=Boundary_only;attribution}])
  | Some
      { B.event =
          B.Turn_ended
            { position =
                (B.Atom_history _ | B.Empty_atom_history | B.No_atom_history | B.Stale_noop)
            ; _
            }
      ; _
      }
  | Some { B.event = B.History_restarted _; _ }
  | None -> gap start_atom end_atom

end
let after ?(include_unread=true) prepared =
  let module H = H_after in
  let module Lines = Map.Make (Int) in
  (* Scopes partition this frozen history in atom order. Label it once and
     pass the remaining suffix on, rather than slicing the full checkpoint
     again for every historical turn and attribution gap. *)
  let labelled, _ = W.annotate prepared.messages in
  let digest_at = W.atom_opening_digest prepared.messages in
  let boundaries = List.fold_left (fun indexed (line, read) ->
    match read with
    | Ok boundary -> Lines.add line boundary indexed
    | Error _ -> indexed) Lines.empty prepared.lines in
  let omitted atom position message =
    List.exists (fun (hole : Keeper_librarian_unread.t) ->
      match hole.source with
      | Keeper_librarian_unread.Atom source ->
        source.trace_id=prepared.trace_id
        && source.history_start_boundary_line=prepared.range.history_start_boundary_line
        && source.atom=atom && source.message_in_atom=position
        && source.message_sha256=Keeper_librarian_unread.message_digest message
      | Keeper_librarian_unread.Official_turn _ -> false) prepared.previous_unread_messages in
  let rec take_span ~start_atom ~end_atom (remaining, last_atom, next_position) retained =
    match remaining with
    | [] -> List.rev retained, ([], last_atom, next_position)
    | (_, W.Pinned) :: rest ->
      take_span ~start_atom ~end_atom (rest, last_atom, next_position) retained
    | (_, W.Atom atom) :: _ when atom >= end_atom ->
      List.rev retained, (remaining, last_atom, next_position)
    | (message, W.Atom atom) :: rest ->
      let position = if last_atom=Some atom then next_position else 0 in
      let retained =
        if atom >= start_atom && (include_unread || not (omitted atom position message))
        then message :: retained else retained in
      take_span ~start_atom ~end_atom (rest, Some atom, position+1) retained in
  (* Keep every validated cut: a selected prefix may stop inside its
     covering turn, and an exact receipt may cover several turns. *)
  let _, _, reversed = List.fold_left (fun (start_atom, cursor, reversed) (cut : R.atom_cut) ->
    let end_atom = min prepared.end_atom cut.cut_end_atom in
    if end_atom <= start_atom then start_atom, cursor, reversed else
    let boundary = Lines.find_opt cut.cut_line boundaries in
    let scopes = H.atom_spans ~trace_id:prepared.trace_id ~digest_at
      ~start_atom ~end_atom ~boundary in
    let cursor, reversed = List.fold_left (fun (cursor, reversed) scope ->
      let messages, cursor = match scope.H.source with
        | H.Atom_span {start_atom;end_atom;_} ->
          take_span ~start_atom ~end_atom cursor []
        | H.Boundary_only | H.Official_turn -> [], cursor in
      cursor, (scope, messages) :: reversed) (cursor, reversed) scopes in
    end_atom, cursor, reversed)
    (prepared.start_atom, (labelled, None, 0), []) prepared.cuts in
  List.rev reversed


let same a b = String.equal (Marshal.to_string a [Marshal.No_sharing]) (Marshal.to_string b [Marshal.No_sharing])
let fixture seed atoms width =
 let random=Random.State.make [|seed|] in
 let id=ref 0 in
 let msg role pinned = incr id; {Agent_core.Types.role;id= !id;pinned} in
 let messages=List.init atoms (fun i ->
  let role = if i=0 && seed mod 3=0 then Agent_core.Types.Tool else if i mod 2=0 then User else Assistant in
  let opener=msg role false in
  let tools=List.init (Random.State.int random 3) (fun _ -> msg Tool false) in
  msg System true :: opener :: (msg User true :: tools)) |> List.concat in
 let digest_at=W.atom_opening_digest messages in
 let count=snd (W.annotate messages) in
 let start_atom=if seed mod 5=0 then count/3 else 0 in
 let end_atom=if seed mod 7=0 then max (start_atom+1) (count-2) else count in
 let boundaries=List.init ((count+width-1)/width) (fun i ->
  let end_atom=min count ((i+1)*width) in
  let digest=Option.get (digest_at (end_atom-1)) in
  let history_at_start=match i mod 4 with
   | 0 -> B.Fresh_history
   | 1 -> Continued_history
   | _ -> let start_atom=max 1 (end_atom-width/2) in
     Continued_history_from {start_atom;start_atom_digest=Option.get (digest_at (start_atom-1))} in
  let record={B.recorded_at=float i;event=B.Turn_ended {turn_ref=("trace",i);task_context=Keeper_turn_task_context.Task i;history_at_start;position=B.Atom_history {end_atom;last_atom_digest=digest}}} in
  (i+1,if seed mod 11=0 && i mod 3=0 then Error "unreadable" else Ok record), {R.cut_line=i+1;cut_end_atom=end_atom}) in
 let labelled,_=W.annotate messages in
 let _,_,holes=List.fold_left (fun (last,pos,holes) (message,label) -> match label with
 | W.Pinned -> last,pos,holes
 | Atom atom -> let pos=if last=Some atom then pos else 0 in
   let holes=if seed mod 2=0 && message.Agent_core.Types.id mod 13=0 then
    {U.source=U.Atom {trace_id="trace";history_start_boundary_line=1;atom;message_in_atom=pos;message_sha256=U.message_digest message};reasons=["refused"]} :: holes else holes in
   Some atom,pos+1,holes) (None,0,[]) labelled in
 {trace_id="trace";messages;lines=List.map fst boundaries;cuts=List.map snd boundaries;range={R.start_atom;end_atom;history_start_boundary_line=1};start_atom;end_atom;previous_unread_messages=holes}
let measure name f =
 Gc.full_major ();let bytes=Gc.allocated_bytes () in let t=Unix.gettimeofday () in
 let value=f () in
 Printf.printf "%s seconds=%.6f allocated_bytes=%.0f\n%!" name (Unix.gettimeofday ()-.t) (Gc.allocated_bytes ()-.bytes);value
let () =
 for i=1 to 500 do
  let p=fixture i (5+i mod 125) (1+i mod 17) in
  List.iter (fun include_unread ->
   if not (same (before ~include_unread p) (after ~include_unread p)) then
    failwith (Printf.sprintf "mismatch seed=%d include_unread=%b" i include_unread)) [true;false]
 done;
 Printf.printf "differential_cases=1000 matched=true\n%!";
 let p=fixture 8 3000 10 in
 let p={p with previous_unread_messages=List.take 3 p.previous_unread_messages} in
 Printf.printf "benchmark_messages=%d cuts=%d\n%!" (List.length p.messages) (List.length p.cuts);
 List.iter (fun include_unread ->
  let a=measure (Printf.sprintf "before include_unread=%b" include_unread) (fun () -> before ~include_unread p) in
  let b=measure (Printf.sprintf "after include_unread=%b" include_unread) (fun () -> after ~include_unread p) in
  if not (same a b) then failwith "benchmark outputs differ") [true;false]
