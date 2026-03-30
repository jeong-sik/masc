(** Loop Guard - Prevents infinite conversation loops

    Detects and prevents:
    1. Max turns exceeded
    2. Identical consecutive messages (spam detection)
    3. Cooldown violations (too rapid posting)

    Based on Hashgraph's gossip protocol for distributed loop prevention.
*)

(** {1 Configuration} *)

type loop_config = {
  max_turns: int;       (** Maximum turns per thread (default: 50) *)
  max_identical: int;   (** Max consecutive identical messages (default: 3) *)
  cooldown_sec: float;  (** Minimum seconds between same speaker (default: 2.0) *)
}

let default_config : loop_config = {
  max_turns = 50;
  max_identical = 3;
  cooldown_sec = 2.0;
}

(** {1 Detection Results} *)

type loop_detection =
  | NoLoop
  | MaxTurnsReached of { current: int; max: int }
  | IdenticalPattern of { content: string; count: int }
  | CooldownViolation of { elapsed_sec: float; required_sec: float }
  | FloorViolation of { holder: string; speaker: string }

let loop_detection_to_string = function
  | NoLoop -> "no_loop"
  | MaxTurnsReached { current; max } ->
      Printf.sprintf "max_turns_reached (current=%d, max=%d)" current max
  | IdenticalPattern { content; count } ->
      let truncated = if String.length content > 20 then String.sub content 0 20 ^ "..." else content in
      Printf.sprintf "identical_pattern (count=%d, content='%s')" count truncated
  | CooldownViolation { elapsed_sec; required_sec } ->
      Printf.sprintf "cooldown_violation (elapsed=%.2fs, required=%.2fs)" elapsed_sec required_sec
  | FloorViolation { holder; speaker } ->
      Printf.sprintf "floor_violation (holder=%s, speaker=%s)" holder speaker

(** {1 Detection Logic} *)

(** Normalize content for comparison (lowercase, trim, collapse whitespace) *)
let normalize_content content =
  content
  |> String.trim
  |> String.lowercase_ascii
  |> String.split_on_char ' '
  |> List.filter (fun s -> String.length s > 0)
  |> String.concat " "

(** Check for identical consecutive messages *)
let check_identical_pattern ~turns ~speaker ~content ~max_identical =
  let normalized = normalize_content content in
  let recent_from_speaker =
    turns
    |> List.rev  (* Most recent first *)
    |> List.filter (fun (t : Conversation.turn) -> t.speaker = speaker)
    |> (fun lst ->
        let rec take n acc = function
          | [] -> List.rev acc
          | _ when n <= 0 -> List.rev acc
          | x :: xs -> take (n - 1) (x :: acc) xs
        in
        take max_identical [] lst)
  in
  let identical_count =
    recent_from_speaker
    |> List.filter (fun (t : Conversation.turn) -> normalize_content t.content = normalized)
    |> List.length
  in
  if identical_count >= max_identical then
    Some (IdenticalPattern { content = normalized; count = identical_count + 1 })
  else
    None

(** Check for cooldown violation *)
let check_cooldown ~turns ~speaker ~cooldown_sec =
  let now = Time_compat.now () in
  let last_turn_from_speaker =
    turns
    |> List.rev
    |> List.find_opt (fun (t : Conversation.turn) -> t.speaker = speaker)
  in
  match last_turn_from_speaker with
  | None -> None
  | Some t ->
      let elapsed = now -. t.created_at in
      if elapsed < cooldown_sec then
        Some (CooldownViolation { elapsed_sec = elapsed; required_sec = cooldown_sec })
      else
        None

(** Check floor holder (SSJ turn-taking) *)
let check_floor ~floor_holder ~speaker =
  match floor_holder with
  | None -> None  (* No floor holder = open floor *)
  | Some holder when holder = speaker -> None  (* Speaker has the floor *)
  | Some _holder ->
      (* Relaxed floor: anyone can respond.
         Future: enforce strict floor with yield/request. *)
      None

(** {1 Main Check Function} *)

(** Check if a proposed message would create a loop condition.
    @param thread The conversation thread
    @param speaker Agent attempting to speak
    @param content Proposed message content
    @param config Loop prevention configuration
    @return NoLoop if safe to proceed, or specific violation detected *)
let check ~(thread : Conversation.thread) ~speaker ~content ~(config : loop_config) : loop_detection =
  (* Check max turns first *)
  if thread.current_turn >= config.max_turns then
    MaxTurnsReached { current = thread.current_turn; max = config.max_turns }
  else
    (* Check identical pattern *)
    match check_identical_pattern ~turns:thread.turns ~speaker ~content ~max_identical:config.max_identical with
    | Some detection -> detection
    | None ->
        (* Check cooldown *)
        match check_cooldown ~turns:thread.turns ~speaker ~cooldown_sec:config.cooldown_sec with
        | Some detection -> detection
        | None ->
            (* Check floor (relaxed for now) *)
            match check_floor ~floor_holder:thread.floor_holder ~speaker with
            | Some detection -> detection
            | None -> NoLoop

(** Check if NoLoop *)
let is_safe detection = detection = NoLoop

(** Get error message for loop detection *)
let to_error_message detection =
  match detection with
  | NoLoop -> None
  | MaxTurnsReached { current; max } ->
      Some (Printf.sprintf "Thread has reached maximum turns (%d/%d). Start a new conversation." current max)
  | IdenticalPattern { count; _ } ->
      Some (Printf.sprintf "Detected %d identical consecutive messages. Please vary your responses." count)
  | CooldownViolation { elapsed_sec; required_sec } ->
      Some (Printf.sprintf "Please wait %.1f more seconds before posting again (cooldown: %.1fs)."
        (required_sec -. elapsed_sec) required_sec)
  | FloorViolation { holder; _ } ->
      Some (Printf.sprintf "Agent '%s' currently has the floor. Wait for them to yield." holder)
