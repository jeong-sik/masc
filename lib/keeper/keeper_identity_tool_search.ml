(* The attached-service surface, offered as a listing instead of as schemas.

   A Keeper attached to a work service is handed that service's entire tool
   list. Measured on 2026-08-29 (RFC-attached-service-tool-scoping §1.5-1.6)
   one Keeper's attached list was 145 tools and 142,257 bytes against 57 KB
   of built-in tools, it was charged to all 83 provider requests of a turn,
   and 20% of those tools were called at all that day. Overflow took 412
   turns, 58.5% of every turn failure.

   So the argument schemas are not sent until they are asked for. What is
   sent is this one tool, whose description names every attached tool with a
   one-line summary -- 9.2% of the bytes -- and whose handler puts the real
   tools into the running agent's callable set. The next provider request of
   the same turn carries their schemas, so the model calls them the ordinary
   way.

   Answering with the schema as tool-result text instead would not work:
   [Agent_tools.admit_tool_use_names] drops a [tool_use] whose name is not in
   [agent.tools] before the history sees it, so the call would disappear
   rather than fail. *)

type deferred =
  { tool : Agent_core.Tool.t
  ; summary : string
  }

type surface =
  { deferred : deferred list
  ; agent_cell : Agent_core.Agent.t option ref
  ; history : Agent_core.Types.message list
  ; carry_window : int
  }

type entry =
  { name : string
  ; summary : string
  ; callable : Agent_core.Tool.t
  }

type turn_discovery =
  | Listing_unused
  | Loaded_and_used
  | Loaded_unused of string list

type placement =
  { tool : Agent_core.Tool.t
  ; already_used : Agent_core.Tool.t list
  ; observe_turn : unit -> turn_discovery
  }

(* Which names this turn made callable, and which of those then ran. Atomic
   rather than a mutex because tools of one turn run in sibling fibers under
   concurrent admission, and a name is added at most once. *)
type usage =
  { loaded : string list Atomic.t
  ; used : string list Atomic.t
  }

let rec note (cell : string list Atomic.t) name =
  let current = Atomic.get cell in
  if List.mem name current
  then ()
  else if Atomic.compare_and_set cell current (name :: current)
  then ()
  else note cell name
;;

let tool_name = "keeper_tool_search"
(** The argument that names tools exactly. *)
let names_param = "names"

(* One line per tool, shown in the answer when the tool is loaded. A line
   longer than this is a paragraph, and the answer is charged to every
   request of the turn from then on. *)
let summary_max_bytes = 80

(* Cutting mid-sequence would put invalid UTF-8 on the wire, so step back to
   the first byte of the character that straddles the cut. *)
let rec character_start s at =
  if at <= 0
  then 0
  else if Char.code (String.unsafe_get s at) land 0xC0 = 0x80
  then character_start s (at - 1)
  else at
;;

let summary_of description =
  let first_line =
    match String.index_opt description '\n' with
    | Some newline -> String.sub description 0 newline
    | None -> description
  in
  let line = String.trim first_line in
  if String.length line <= summary_max_bytes
  then line
  else String.sub line 0 (character_start line summary_max_bytes) ^ "..."
;;

(* The fixed half of what the model reads lives in
   config/tools/keeper_tool_search.toml with every other tool's prose; only
   the listing is built here, because only this turn knows what is attached. *)
let declared = Tool_schemas_identity_tool_search.schema

(* [placed] are the entries this turn hands over with their schemas, so the
   model reads them from its own tool list. Naming them here as well would
   spend the listing's bytes -- charged to every request of the turn -- on a
   name the schema beside it already carries. Measured over three days, that
   duplication was a median 7 of the listed tools and reached 24, a third of
   one listing. They stay in [entries]: asking for a tool that is already
   callable answers rather than refuses.

   Names only. The one-line summaries rode here too until 2026-09-02, and at
   57 to 86 listed tools that was 6 to 9 KB on every request of every turn,
   7 to 14% of the whole tool surface. A summary is shown when its tool is
   loaded, once, in the answer. *)
let description_of ~placed entries =
  let omitted name = List.exists (String.equal name) placed in
  match
    List.filter_map
      (fun entry -> if omitted entry.name then None else Some entry.name)
      entries
  with
  | [] -> declared.Masc_domain.description
  | names -> declared.Masc_domain.description ^ "\n" ^ String.concat ", " names
;;


let refusal message =
  Error
    { Agent_core.Types.message
    ; recoverable = true
    ; error_class = Some Agent_core.Types.Deterministic
    }
;;

let requested_names input =
  let of_item = function
    | `String name -> Ok name
    | other ->
      Error
        (Printf.sprintf
           "\"%s\" must hold strings; found %s"
           names_param
           (Yojson.Safe.to_string other))
  in
  match input with
  | `Assoc fields ->
    (match List.assoc_opt names_param fields with
     | Some (`List []) ->
       Error (Printf.sprintf "\"%s\" was empty; name at least one tool" names_param)
     | Some (`List items) ->
       Result.map
         (List.sort_uniq String.compare)
         (Agent_core.Types.result_all (List.map of_item items))
     | Some other ->
       Error
         (Printf.sprintf
            "\"%s\" must be an array of tool names; found %s"
            names_param
            (Yojson.Safe.to_string other))
     | None -> Error (Printf.sprintf "\"%s\" is required" names_param))
  | other ->
    Error
      (Printf.sprintf
         "arguments must be an object with \"%s\"; found %s"
         names_param
         (Yojson.Safe.to_string other))
;;

let describe entry = Printf.sprintf "- %s: %s" entry.name entry.summary

(* Puts [found] into the running agent's callable set and answers with what
   each one does, so the model can pick among what it just loaded without
   waiting for the schemas of the next request. *)
let load_found ~agent ~usage found =
  Agent_core.Agent.extend_tools agent (List.map (fun entry -> entry.callable) found);
  List.iter (fun entry -> note usage.loaded entry.name) found;
  "now callable:\n" ^ String.concat "\n" (List.map describe found)
;;

let load ~keeper_name ~agent_cell ~entries ~usage requested =
  match !agent_cell with
  | None ->
    (* The cell is filled at agent creation, so an empty one here means the
       turn was wired without it and no attached tool can ever be reached.
       Loud rather than an empty answer: the model would read "nothing
       matched" and stop asking. *)
    Log.Keeper.emit
      Log.Error
      ~keeper_name
      ~category:Log.Tool
      ~details:
        (`Assoc
           [ "error_kind", `String "keeper_identity_tool_search_no_agent"
           ; "requested", Json_util.json_string_list requested
           ])
      "Attached tool listing has no running agent to make tools callable";
    Error
      { Agent_core.Types.message =
          "this turn has no agent to make the tool callable in; the attached \
           surface cannot be reached"
      ; recoverable = false
      ; error_class = Some Agent_core.Types.Deterministic
      }
  | Some agent ->
   let found, unknown =
     List.partition_map
       (fun name ->
          match List.find_opt (fun entry -> String.equal entry.name name) entries with
          | Some entry -> Either.Left entry
          | None -> Either.Right name)
       requested
   in
   (match found with
    | [] ->
      refusal (Printf.sprintf "not in the list: %s" (String.concat ", " unknown))
    | _ :: _ ->
      let loaded = load_found ~agent ~usage found in
      let content =
        match unknown with
        | [] -> loaded
        | _ :: _ ->
          Printf.sprintf "%s\nnot in the list: %s" loaded (String.concat ", " unknown)
      in
      Ok { Agent_core.Types.content; _meta = None })
;;

(* Same tool, and it also says it ran. The wrapper keeps the descriptor so
   the schedule this tool is admitted under does not change. *)
let observed usage (tool : Agent_core.Tool.t) =
  { tool with
    Agent_core.Tool.handler =
      (fun env input ->
        note usage.used tool.Agent_core.Tool.schema.name;
        tool.Agent_core.Tool.handler env input)
  }
;;

let observe_turn ~keeper_name ~usage () =
  match Atomic.get usage.loaded, Atomic.get usage.used with
  | [], _ -> Listing_unused
  | _ :: _, _ :: _ -> Loaded_and_used
  | (_ :: _ as loaded), [] ->
    let loaded = List.rev loaded in
    Log.Keeper.emit
      Log.Warn
      ~keeper_name
      ~category:Log.Tool
      ~details:
        (`Assoc
           [ "error_kind", `String "keeper_attached_tool_loaded_unused"
           ; "loaded", Json_util.json_string_list loaded
           ])
      "A turn loaded attached tools and called none of them";
    Loaded_unused loaded
;;

(* Which attached tools this conversation carries with their schemas, and
   which of the ones it ran are no longer carried.

   Read off the tools' own ToolUse blocks: a call the model made is a call the
   model needed, and the block carries the tool's name directly. Nothing about
   the listing is parsed -- the request for a tool is not evidence that the
   tool was wanted, only that it looked wanted. Carrying every requested tool
   grows the surface back toward the full attached list: measured 2026-08-30
   after one hour, polisher was at 111 tools of a possible 133 and still
   climbing.

   Carrying everything ever used has no upper bound either, only a slower one.
   Measured over 19,100 turns 2026-09-01..03, the per-keeper median carried
   was 32.1 KB of schema and reached 51.9 KB, against a re-use gap whose
   median is 2 turns and whose p90 is 24: most of what was carried was last
   used far outside the work still in progress.

   So the carry is cut back to [carry_window], and cut on the calls that grow
   it -- a call to a name the carry does not already hold. The tool array is
   the head of the provider's cache prefix, so every turn whose array differs
   from the turn before pays the whole prefix again. A call to a name already
   carried only moves that name's ordinal, which leaves the array identical,
   so cutting there would forfeit the prefix for a change nothing else asked
   for. A call to a name not carried adds it to the array, which forfeits the
   prefix anyway, so the cut rides an invalidation already being paid.

   The consequence is that the window is sampled at those calls and not
   continuously: between two of them the carried set is frozen, so a tool can
   age past [carry_window] and stay placed until the next call grows the
   carry. A Keeper that stops reaching for tools it is not already carrying
   stops evicting. The alternative is cutting on every call, which pays a full
   prefix on turns whose array would otherwise be byte-identical.

   [ordinal] counts every ToolUse block, not only the offered ones: the window
   measures distance back through the conversation, and a built-in call fills
   the conversation the same way an attached one does. *)
let carry_from_history ~carry_window ~entries history =
  (* One membership table for the offering rather than a scan per block:
     [observe] runs on every ToolUse block in the whole history, built-ins
     included, and history is not pruned, so a scan here is the attached list
     (145 tools on the largest measured Keeper) times the conversation. *)
  let offered_names : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  List.iter (fun (entry : entry) -> Hashtbl.replace offered_names entry.name ()) entries;
  let offered name = Hashtbl.mem offered_names name in
  (* Name and the ordinal of its most recent call. A list because the largest
     carried set measured over three days was 41 tools. *)
  let carried : (string * int) list ref = ref [] in
  let ever : string list ref = ref [] in
  let ordinal = ref 0 in
  let observe name =
    incr ordinal;
    if offered name
    then begin
      if not (List.exists (String.equal name) !ever) then ever := name :: !ever;
      let others =
        List.filter (fun (carried_name, _) -> not (String.equal carried_name name)) !carried
      in
      (* [others] is [!carried] without [name], so it is shorter exactly when
         the carry already held it. That is the test for whether this call
         grows the array, and it is true again for a name the window dropped
         earlier -- which is what keeps a re-used name from re-entering the
         carry without the rest of it being measured. *)
      let grows = List.compare_lengths others !carried = 0 in
      let grown = (name, !ordinal) :: others in
      carried
        := (if grows && carry_window > 0
            then List.filter (fun (_, seen) -> !ordinal - seen <= carry_window) grown
            else grown)
    end
  in
  List.iter
    (fun (message : Agent_core.Types.message) ->
       List.iter
         (fun (block : Agent_core.Types.content_block) ->
            match block with
            | Agent_core.Types.ToolUse { name; _ } -> observe name
            | Agent_core.Types.Text _
            | Agent_core.Types.Thinking _
            | Agent_core.Types.RedactedThinking _
            | Agent_core.Types.ToolResult _
            | Agent_core.Types.Image _
            | Agent_core.Types.Document _
            | Agent_core.Types.ReasoningDetails _
            | Agent_core.Types.Audio _ -> ())
         message.Agent_core.Types.content)
    history;
  let carried_names = List.map (fun (carried_name, _) -> carried_name) !carried in
  let held name = List.exists (String.equal name) carried_names in
  (* Ran at some point in this conversation and not carried now. The only
     input an operator has for deciding whether the window is too tight. *)
  let dropped = List.filter (fun name -> not (held name)) (List.rev !ever) in
  carried_names, dropped
;;

(* [entries] order, not carry order: the tool array is a cache prefix keyed by
   the exact bytes in the exact order sent, so a tool that leaves the window
   and comes back must come back in the slot it left. *)
let already_used_from_history ~carry_window ~entries history =
  let carried_names, dropped = carry_from_history ~carry_window ~entries history in
  let placed =
    List.filter_map
      (fun entry ->
         if List.exists (String.equal entry.name) carried_names
         then Some entry.callable
         else None)
      entries
  in
  placed, carried_names, dropped
;;

let make ~keeper_name { deferred; agent_cell; history; carry_window } =
  match deferred with
  | [] -> None
  | _ :: _ ->
    let usage = { loaded = Atomic.make []; used = Atomic.make [] } in
    let entries =
      List.map
        (fun (d : deferred) ->
           { name = d.tool.Agent_core.Tool.schema.name
           ; summary = d.summary
           ; callable = observed usage d.tool
           })
        deferred
    in
    let already_used, carried_names, dropped =
      already_used_from_history ~carry_window ~entries history
    in
    (match dropped with
     | [] -> ()
     | _ :: _ ->
       (* State, not an event, and named as one. [dropped] is recomputed by
          replaying the whole history every turn, so once a tool is outside
          the window every later turn recomputes the same answer: this line
          says what the carry holds now, and it says it on every turn of the
          rest of the conversation. It cannot say "a cut happened this turn",
          because the turn boundary is not recoverable from a flat message
          list -- the same reason the window is counted in tool calls.

          [Debug] for that reason rather than [Info]: a per-turn line for the
          life of a conversation is not an event an operator should be shown
          by default, and a tool ageing out of the window is what the window
          is for. The names rather than a count -- a count cannot say whether
          the window is too tight for this Keeper, which is the only question
          an operator tuning it has.

          [error_kind] is the key every other emit in this directory uses. *)
       Log.Keeper.emit
         Log.Debug
         ~keeper_name
         ~category:Log.Tool
         ~details:
           (`Assoc
              [ "error_kind", `String "keeper_attached_tool_carry_state"
              ; "carry_window", `Int carry_window
              ; "carried", `Int (List.length carried_names)
              ; "dropped", Json_util.json_string_list dropped
              ])
         "Tools this conversation ran are outside the carry window");
    let placed =
      List.map
        (fun (tool : Agent_core.Tool.t) -> tool.Agent_core.Tool.schema.name)
        already_used
    in
    let schema =
      match
        Agent_core.Types.tool_schema_of_input_schema
          ~name:tool_name
          ~description:(description_of ~placed entries)
          ~input_schema:declared.Masc_domain.input_schema
          ()
      with
      | Ok schema -> schema
      | Error reason ->
        (* The schema above is a literal, so this is a defect in it rather
           than anything an operator configured. Failing here beats offering
           the attached surface as a list the model cannot act on. *)
        invalid_arg
          (Printf.sprintf "%s has a malformed argument schema: %s" tool_name reason)
    in
    let handler input =
      match requested_names input with
      | Error message -> refusal message
      | Ok requested -> load ~keeper_name ~agent_cell ~entries ~usage requested
    in
    Some
      { tool =
          Agent_core.Tool.of_schema
            schema
            (Agent_core.Tool.ignoring_execution_env handler)
      ; already_used
      ; observe_turn = observe_turn ~keeper_name ~usage
      }
;;
