(** trpg_bdi.ml -- BDI (Belief-Desire-Intention) Memory Module.

    Based on CharacterBox (NAACL 2025) BDI mechanisms.
    Each Keeper maintains beliefs (with confidence decay),
    desires (prioritized goals), and intentions (active plans).

    @since 2.70.0 *)

open Printf

(* ---------- Types ---------- *)

type belief = {
  subject : string;
  content : string;
  confidence : float;
  source_turn : int;
  last_reinforced : int;
}
[@@deriving yojson, show, eq]

type desire = {
  goal : string;
  priority : float;
  category : string;
  active : bool;
}
[@@deriving yojson, show, eq]

type intention = {
  plan : string;
  target_desire : string;
  progress : float;
  blocked : bool;
}
[@@deriving yojson, show, eq]

type bdi_state = {
  actor_id : string;
  beliefs : belief list;
  desires : desire list;
  intentions : intention list;
  turn_number : int;
}
[@@deriving yojson, show, eq]

(* ---------- Constructor ---------- *)

let empty ~actor_id =
  { actor_id; beliefs = []; desires = []; intentions = []; turn_number = 0 }

(* ---------- Decay ---------- *)

let decay_factor = 0.95

let decay_single_belief ~current_turn (b : belief) : belief =
  let delta = current_turn - b.last_reinforced in
  if delta <= 0 then b
  else
    let decayed = b.confidence *. Float.pow decay_factor (Float.of_int delta) in
    { b with confidence = decayed }

let decay_beliefs ~current_turn (st : bdi_state) : bdi_state =
  let beliefs = List.map (decay_single_belief ~current_turn) st.beliefs in
  { st with beliefs; turn_number = current_turn }

(* ---------- Belief update ---------- *)

let update_belief ~subject ~content ~confidence ~turn (st : bdi_state) : bdi_state =
  let found = ref false in
  let beliefs =
    List.map
      (fun (b : belief) ->
        if b.subject = subject then begin
          found := true;
          { b with content; confidence; last_reinforced = turn }
        end
        else b)
      st.beliefs
  in
  let beliefs =
    if !found then beliefs
    else
      beliefs
      @ [
          {
            subject;
            content;
            confidence;
            source_turn = turn;
            last_reinforced = turn;
          };
        ]
  in
  { st with beliefs; turn_number = turn }

(* ---------- Desire update ---------- *)

let update_desire ~goal ~priority ~category (st : bdi_state) : bdi_state =
  let found = ref false in
  let desires =
    List.map
      (fun (d : desire) ->
        if d.goal = goal then begin
          found := true;
          { d with priority; category }
        end
        else d)
      st.desires
  in
  let desires =
    if !found then desires
    else desires @ [{ goal; priority; category; active = true }]
  in
  { st with desires }

let deactivate_desire ~goal (st : bdi_state) : bdi_state =
  let desires =
    List.map
      (fun (d : desire) ->
        if d.goal = goal then { d with active = false } else d)
      st.desires
  in
  { st with desires }

(* ---------- Intention update ---------- *)

let update_intention ~plan ~target_desire ~progress (st : bdi_state) : bdi_state =
  let found = ref false in
  let intentions =
    List.map
      (fun (i : intention) ->
        if i.plan = plan then begin
          found := true;
          { i with target_desire; progress }
        end
        else i)
      st.intentions
  in
  let intentions =
    if !found then intentions
    else intentions @ [{ plan; target_desire; progress; blocked = false }]
  in
  { st with intentions }

let block_intention ~plan (st : bdi_state) : bdi_state =
  let intentions =
    List.map
      (fun (i : intention) ->
        if i.plan = plan then { i with blocked = true } else i)
      st.intentions
  in
  { st with intentions }

(* ---------- Pruning ---------- *)

let prune_beliefs ?(threshold = 0.1) (st : bdi_state) : bdi_state =
  let beliefs =
    List.filter (fun (b : belief) -> b.confidence >= threshold) st.beliefs
  in
  { st with beliefs }

(* ---------- Prompt fragment ---------- *)

let confidence_label (c : float) : string =
  if c >= 0.7 then "high"
  else if c >= 0.4 then "med"
  else "low"

let priority_label (p : float) : string =
  if p >= 0.7 then "high"
  else if p >= 0.4 then "med"
  else "low"

let truncate_to ~max_len (s : string) : string =
  if String.length s <= max_len then s
  else String.sub s 0 max_len

let to_prompt_fragment ?(max_len = 800) (st : bdi_state) : string =
  let buf = Buffer.create 256 in
  Buffer.add_string buf "[Memory]\n";
  (* Beliefs: only confidence > 0.3 *)
  let visible_beliefs =
    List.filter (fun (b : belief) -> b.confidence > 0.3) st.beliefs
  in
  if visible_beliefs <> [] then begin
    Buffer.add_string buf "Beliefs: ";
    let parts =
      List.map
        (fun (b : belief) ->
          sprintf "\"%s\" (%s)" b.content (confidence_label b.confidence))
        visible_beliefs
    in
    Buffer.add_string buf (String.concat ", " parts);
    Buffer.add_char buf '\n'
  end;
  (* Goals: only active desires *)
  let active_desires =
    List.filter (fun (d : desire) -> d.active) st.desires
  in
  if active_desires <> [] then begin
    Buffer.add_string buf "Goals: ";
    let parts =
      List.map
        (fun (d : desire) ->
          sprintf "%s (%s)" d.goal (priority_label d.priority))
        active_desires
    in
    Buffer.add_string buf (String.concat ", " parts);
    Buffer.add_char buf '\n'
  end;
  (* Plans: only non-completed intentions (progress < 1.0) *)
  let active_intentions =
    List.filter (fun (i : intention) -> i.progress < 1.0) st.intentions
  in
  if active_intentions <> [] then begin
    let parts =
      List.map
        (fun (i : intention) ->
          let pct = int_of_float (i.progress *. 100.0) in
          let blocked_suffix = if i.blocked then " [blocked]" else "" in
          sprintf "Plan: %s (%d%%)%s" i.plan pct blocked_suffix)
        active_intentions
    in
    Buffer.add_string buf (String.concat "\n" parts);
    Buffer.add_char buf '\n'
  end;
  truncate_to ~max_len (Buffer.contents buf)

(* ---------- Serialization ---------- *)

let to_yojson = bdi_state_to_yojson

let of_yojson = bdi_state_of_yojson

(* ---------- File I/O ---------- *)

let bdi_path ~room_dir ~actor_id =
  Filename.concat room_dir (sprintf "bdi_%s.json" actor_id)

let load ~room_dir ~actor_id =
  let path = bdi_path ~room_dir ~actor_id in
  try
    let json = Util.read_json_eio path in
    match of_yojson json with
    | Ok st -> st
    | Error _e -> empty ~actor_id
  with
  | _exn -> empty ~actor_id

let save ~room_dir (st : bdi_state) : (unit, string) result =
  let path = bdi_path ~room_dir ~actor_id:st.actor_id in
  try
    let json = to_yojson st in
    Yojson.Safe.to_file path json;
    Ok ()
  with exn ->
    Error (sprintf "failed to save BDI state to %s: %s" path (Printexc.to_string exn))
