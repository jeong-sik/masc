(** Mention parsing module - Stateless/Stateful/Broadcast routing modes

    @mention 문법:
    - @@agent           → Broadcast to ALL agents of this type
    - @agent-adj-animal → Stateful (specific agent by nickname)
    - @agent            → Stateless (pick one available agent)
*)

(** Mention routing mode *)
type mode =
  | Stateless of string       (** @agent → pick one available *)
  | Stateful of string        (** @agent-adj-animal → specific agent *)
  | Broadcast of string       (** @@agent → all of type *)
  | None                      (** No mention found *)

(** Convert mode to string for logging *)
let mode_to_string = function
  | Stateless s -> Printf.sprintf "Stateless(%s)" s
  | Stateful s -> Printf.sprintf "Stateful(%s)" s
  | Broadcast s -> Printf.sprintf "Broadcast(%s)" s
  | None -> "None"

(** Extract agent type from mention (e.g., "local-gentle-gecko" → "local") *)
let agent_type_of_mention mention =
  let parts = String.split_on_char '-' mention in
  match parts with
  | [] -> mention
  | base :: _ ->
      if String.length base > 0 then base
      else mention

(** Check if a mention is a generated nickname (agent-adjective-animal pattern) *)
let is_nickname mention =
  let parts = String.split_on_char '-' mention in
  List.length parts >= 3

(** Parse @mention from message content

    Priority order:
    1. @@agent → Broadcast
    2. @agent-adj-animal → Stateful
    3. @agent → Stateless
*)
let parse content =
  (* Pattern 1: @@agent (broadcast) *)
  let broadcast_re = Re.(compile (seq [str "@@"; group (rep1 (alt [rg 'a' 'z'; rg 'A' 'Z'; rg '0' '9'; char '_']))])) in
  match Re.exec_opt broadcast_re content with
  | Some g -> Broadcast (Re.Group.get g 1)
  | None ->
    (* Pattern 2: @agent-xxx-yyy (stateful - 3+ parts, alphanumeric allowed) *)
    let stateful_re = Re.(compile (seq [
      char '@';
      group (seq [
        rep1 (alt [rg 'a' 'z'; rg 'A' 'Z'; rg '0' '9'; char '_']);
        char '-';
        rep1 (alt [rg 'a' 'z'; rg 'A' 'Z'; rg '0' '9']);
        char '-';
        rep1 (alt [rg 'a' 'z'; rg 'A' 'Z'; rg '0' '9'])
      ])
    ])) in
    match Re.exec_opt stateful_re content with
    | Some g -> Stateful (Re.Group.get g 1)
    | None ->
      (* Pattern 3: @agent (stateless) or @agent-something (stateful) *)
      let mention_re = Re.(compile (seq [char '@'; group (rep1 (alt [rg 'a' 'z'; rg 'A' 'Z'; rg '0' '9'; char '_'; char '-']))])) in
      match Re.exec_opt mention_re content with
      | Some g ->
        let matched = Re.Group.get g 1 in
        (* Heuristic: if contains hyphen but not 3-part nickname, still stateful *)
        if String.contains matched '-' then
          Stateful matched
        else
          Stateless matched
      | None -> None

(** Extract raw mention target (backward-compatible with old extract_mention) *)
let extract content =
  match parse content with
  | Stateless s -> Some s
  | Stateful s -> Some s
  | Broadcast s -> Some s
  | None -> None

(** Get target agents based on mode

    Returns:
    - Stateless: First available agent of type
    - Stateful: Specific agent (exact match)
    - Broadcast: All agents of type
*)
let resolve_targets mode ~available_agents =
  match mode with
  | None -> []
  | Stateless agent_type ->
      (* Find first agent matching type *)
      available_agents
      |> List.filter (fun name -> agent_type_of_mention name = agent_type)
      |> (fun l -> match l with [] -> [] | first :: _ -> [first])
  | Stateful nickname ->
      (* Exact match only *)
      if List.mem nickname available_agents then [nickname] else []
  | Broadcast agent_type ->
      (* All agents of type *)
      available_agents
      |> List.filter (fun name -> agent_type_of_mention name = agent_type)

let is_mentioned target content =
  let target = String.trim target in
  if target = "" then
    false
  else
    let re = Re.(compile (seq [
      (* Start of string or non-mention character *)
      group (alt [bos; compl [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '@'; char '_'; char '-']]);
      no_case (seq [char '@'; str target]);
      (* End of string or non-mention character *)
      group (alt [eos; compl [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '_'; char '-']])
    ])) in
    Re.execp re content

let any_mentioned ~targets content =
  targets
  |> List.filter (fun target -> String.trim target <> "")
  |> List.exists (fun target -> is_mentioned target content)

