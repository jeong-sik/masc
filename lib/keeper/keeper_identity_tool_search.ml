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
  ; receipts : Keeper_tool_load_receipts.t
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

(* The argument that names tools exactly. *)
let names_param = "names"

(* One line per tool, shown in the answer when the tool is loaded. A line
   longer than this is a paragraph, and the answer is charged to every
   request of the turn from then on. *)
let summary_max_bytes = 80

let summary_of description =
  let first_line =
    match String.index_opt description '\n' with
    | Some newline -> String.sub description 0 newline
    | None -> description
  in
  let line = String.trim first_line in
  if String.length line <= summary_max_bytes
  then line
  else
    (* Cutting mid-sequence would put invalid UTF-8 on the wire. *)
    String_util.utf8_prefix ~max_bytes:summary_max_bytes line ^ "..."
;;

(* The fixed half of what the model reads lives in
   config/tools/keeper_tool_search.toml with every other tool's prose; only
   the listing is built here, because only this turn knows what is attached. *)
let declared = Tool_schemas_identity_tool_search.schema

(* Every entry, including the ones this turn also places with their schemas.
   This description sits in the tool array, which is the head of the
   provider's cache prefix, so it has to read the same on the turn that loads
   a tool and on the turn after, when that tool is placed. Leaving placed names
   out would change the description at exactly that boundary and forfeit the
   cached prefix from this tool on, history included. Over 1,694 requests in
   two capture files of 2026-09-17, naming them cost a median 143 bytes and a
   p90 of 375, 0.21% of the median 73 KB of tool schemas; the largest carried
   set measured, 41 tools, is under 1 KB of names. Asking for a tool that is
   already callable answers rather than refuses.

   Names only. The one-line summaries rode here too until 2026-09-02, and at
   57 to 86 listed tools that was 6 to 9 KB on every request of every turn,
   7 to 14% of the whole tool surface. A summary is shown when its tool is
   loaded, once, in the answer. *)
let description_of entries =
  match List.map (fun entry -> entry.name) entries with
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

(* task-3268: mirror an agent-core search outcome into the typed result the
   shared dispatch observers read, so keeper_tool_search calls reach
   tool_metric_events (#38824). The mapping inverts
   [Tool_projection.agent_core_error_class_of_tool_failure_class]: Transient
   is Dependency_unavailable, Unknown is Runtime_failure, and a recoverable
   Deterministic refusal is a caller-argument Policy_rejection (corrected
   arguments may succeed). A non-recoverable Deterministic error is a wiring
   or state defect, hence Runtime_failure; [None] only arises without an
   execution identity, also a wiring defect. Every refusal below is proven
   pre-effect: no tool is extended or dispatched on those paths. *)
let metrics_result ~tool_name ~start_time (outcome : Agent_core.Types.tool_result) =
  match outcome with
  | Ok { Agent_core.Types.content; _ } ->
    Tool_result.make_ok ~tool_name ~start_time ~data:(`String content) ()
  | Error { Agent_core.Types.message = message; recoverable; error_class } ->
    let class_ =
      match error_class with
      | Some Agent_core.Types.Transient -> Tool_result.Dependency_unavailable
      | Some Agent_core.Types.Unknown -> Tool_result.Runtime_failure
      | Some Agent_core.Types.Deterministic when recoverable -> Tool_result.Policy_rejection
      | Some Agent_core.Types.Deterministic | None -> Tool_result.Runtime_failure
    in
    Tool_result.make_err
      ~tool_name
      ~class_
      ~start_time
      ~effect_disposition:Tool_result.Proven_pre_effect
      message
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
   waiting for the schemas of the next request.

   In the slot the next turn places it: the bundle builds that turn's array as
   this tool followed by the placed entries in [entries] order, so the loaded
   tool is ranked the same way here. Appended at the end instead, the array
   the rest of this turn sends and the array the next turn sends would hold
   the same tools in a different order, and the turn boundary would forfeit
   the cached prefix a second time. *)
let load_found ~agent ~entries ~usage ~receipts ~invocation found =
  match
    Keeper_tool_load_receipts.loaded
      receipts
      ~invocation
      ~names:(List.map (fun entry -> entry.name) found)
      ~apply:(fun () ->
        Agent_core.Agent.extend_tools
          ~order:(tool_name :: List.map (fun entry -> entry.name) entries)
          agent
          (List.map (fun entry -> entry.callable) found))
  with
  | Error (Keeper_tool_load_receipts.Work_scope_unavailable _ as error) ->
    Error
      { Agent_core.Types.message = Keeper_tool_load_receipts.error_to_string error
      ; recoverable = true
      ; error_class = Some Agent_core.Types.Transient
      }
  | Error (Keeper_tool_load_receipts.Invalid_snapshot _ as error) ->
    Error
      { Agent_core.Types.message = Keeper_tool_load_receipts.error_to_string error
      ; recoverable = false
      ; error_class = Some Agent_core.Types.Deterministic
      }
  | Ok () ->
    List.iter (fun entry -> note usage.loaded entry.name) found;
    Ok ("now callable:\n" ^ String.concat "\n" (List.map describe found))
;;

let load ~held_schemas ~keeper_name ~agent_cell ~entries ~usage ~receipts ~invocation requested =
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
          "this turn has no agent to make the tool callable in; the attached surface \
           cannot be reached"
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
    (* The listing names placed tools too, so asking for one the agent already
       holds is expected. Loading it again would add nothing, record a receipt
       that keeps it placed past the carry window, and report it loaded. *)
    let found, found_held =
      List.partition
        (fun entry ->
           not (Agent_core.Tool_set.mem entry.name (Agent_core.Agent.tools agent)))
        found
    in
    let callable, unknown =
      List.partition_map
        (fun name ->
           let admitted = match held_schemas with
             | None -> true
             | Some schemas -> List.exists
                 (fun (schema : Agent_core.Types.tool_schema) -> String.equal schema.name name) schemas
           in
           match if admitted then Agent_core.Tool_set.find name (Agent_core.Agent.tools agent)
                 else None with
           | Some tool ->
             Either.Left
               (Printf.sprintf "- %s: %s" name
                  (summary_of tool.Agent_core.Tool.schema.description))
           | None -> Either.Right name)
        unknown
    in
    let callable = List.map describe found_held @ callable in
    match found, callable with
    | [], [] -> refusal (Printf.sprintf "not in the list: %s" (String.concat ", " unknown))
    | _ ->
      let loaded = match found with
        | [] -> Ok []
        | _ :: _ ->
          load_found ~agent ~entries ~usage ~receipts ~invocation found
          |> Result.map (fun content -> [content])
      in
      Result.map
        (fun loaded ->
           let available = match callable with
             | [] -> []
             | _ -> ["already callable:\n" ^ String.concat "\n" callable]
           in
           let missing = match unknown with
             | [] -> []
             | _ -> ["not in the list: " ^ String.concat ", " unknown]
           in
           { Agent_core.Types.content = String.concat "\n" (loaded @ available @ missing)
           ; content_blocks = None; _meta = None })
        loaded
;;

(* Observe actual ordinary or producer-prepared dispatch through the same
   wrapper. A preparation refusal never enters either handler and therefore
   does not consume its outstanding load receipt. *)
let observed usage receipts (tool : Agent_core.Tool.t) =
  Agent_core.Tool.map_handler
      (fun handler env input ->
        Keeper_tool_load_receipts.dispatched
          receipts
          ~name:tool.Agent_core.Tool.schema.name;
        note usage.used tool.Agent_core.Tool.schema.name;
        handler env input)
      tool
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
   for. A call to a name not carried adds it to the array the turn started
   with, which forfeits the prefix anyway, so the cut rides an invalidation
   already being paid -- except when that name was loaded through the listing
   during the turn. Its later requests already held it in the slot this turn
   places it in, so there the cut is the only change at the boundary. That
   cost is kept: measured 2026-09-17 it was about 0.2% of the fleet's uncached
   input a day, on one provider (#36947).

   The consequence is that the window is sampled at those calls and not
   continuously: between two of them the carried set is frozen, so a tool can
   age past [carry_window] and stay placed until the next call grows the
   carry. A Keeper that stops reaching for tools it is not already carrying
   stops evicting. The alternative is cutting on every call, which pays a full
   prefix on turns whose array would otherwise be byte-identical.

   [ordinal] counts every ToolUse block, not only the offered ones: the window
   measures distance back through the conversation, and a built-in call fills
   the conversation the same way an attached one does. *)
module Tool_name_set = Set.Make (String)

let carry_from_history ~carry_window ~entries history =
  (* One membership set for the offering rather than a scan per block:
     [observe] runs on every ToolUse block in the whole history, built-ins
     included, and history is not pruned, so a scan here is the attached list
     (145 tools on the largest measured Keeper) times the conversation. *)
  let offered_names =
    List.fold_left
      (fun acc (entry : entry) -> Tool_name_set.add entry.name acc)
      Tool_name_set.empty
      entries
  in
  let offered name = Tool_name_set.mem name offered_names in
  (* Name and the ordinal of its most recent call. A list because the largest
     carried set measured over three days was 41 tools. *)
  let observe (carried, ever_set, ever_rev, ordinal) name =
    let ordinal = ordinal + 1 in
    if not (offered name)
    then carried, ever_set, ever_rev, ordinal
    else (
      let ever_set, ever_rev =
        if Tool_name_set.mem name ever_set
        then ever_set, ever_rev
        else Tool_name_set.add name ever_set, name :: ever_rev
      in
      let others =
        List.filter (fun (carried_name, _) -> not (String.equal carried_name name)) carried
      in
      (* [others] is [carried] without [name], so it is shorter exactly when
         the carry already held it. That is the test for whether this call
         grows the array, and it is true again for a name the window dropped
         earlier -- which is what keeps a re-used name from re-entering the
         carry without the rest of it being measured. *)
      let grows = List.compare_lengths others carried = 0 in
      let grown = (name, ordinal) :: others in
      let carried =
        if grows && carry_window > 0
        then List.filter (fun (_, seen) -> ordinal - seen <= carry_window) grown
        else grown
      in
      carried, ever_set, ever_rev, ordinal)
  in
  let carried, _ever_set, ever_rev, _ordinal =
    List.fold_left
      (fun acc (message : Agent_core.Types.message) ->
         List.fold_left
           (fun acc (block : Agent_core.Types.content_block) ->
              match block with
              | Agent_core.Types.ToolUse { name; _ } -> observe acc name
              | Agent_core.Types.Text _
              | Agent_core.Types.Thinking _
              | Agent_core.Types.RedactedThinking _
              | Agent_core.Types.ToolResult _
              | Agent_core.Types.Image _
              | Agent_core.Types.Document _
              | Agent_core.Types.ReasoningDetails _
              | Agent_core.Types.Audio _ -> acc)
           acc
           message.Agent_core.Types.content)
      ([], Tool_name_set.empty, [], 0)
      history
  in
  let carried_names = List.map (fun (carried_name, _) -> carried_name) carried in
  let held_set = Tool_name_set.of_list carried_names in
  (* Ran at some point in this conversation and not carried now. The only
     input an operator has for deciding whether the window is too tight. *)
  let dropped =
    List.filter (fun name -> not (Tool_name_set.mem name held_set)) (List.rev ever_rev)
  in
  carried_names, dropped
;;

(* [entries] order, not carry order: the tool array is a cache prefix keyed by
   the exact bytes in the exact order sent, so a tool that leaves the window
   and comes back must come back in the slot it left. *)
let already_used_from_history ~carry_window ~entries ~receipts history =
  let carried_names, dropped = carry_from_history ~carry_window ~entries history in
  (* Successful loads stay callable until their own dispatch, a changed
     work/surface scope, or the end of the turn after the one that made them
     ([Keeper_tool_load_receipts.create]). Sibling calls say nothing about
     whether a loaded tool is still needed. Carry diagnostics describe actual
     use separately. *)
  let pending = Keeper_tool_load_receipts.pending_names receipts in
  let placed_name name =
    List.exists (String.equal name) carried_names
    || List.exists (String.equal name) pending
  in
  let placed =
    List.filter_map
      (fun entry -> if placed_name entry.name then Some entry.callable else None)
      entries
  in
  placed, carried_names, dropped
;;

let make ?(carried=[]) ?held_schemas ~keeper_name { deferred; agent_cell; history; carry_window; receipts } =
  match deferred with
  | [] -> None
  | _ :: _ ->
    let usage = { loaded = Atomic.make []; used = Atomic.make [] } in
    let entries =
      List.map
        (fun (d : deferred) ->
           { name = d.tool.Agent_core.Tool.schema.name
           ; summary = d.summary
           ; callable = observed usage receipts d.tool
           })
        deferred
    in
    let already_used, carried_names, dropped =
      already_used_from_history ~carry_window ~entries ~receipts history
    in
    (* Resolve prior loaded names only inside this view. Never transplant a
       previous attempt's callable or its broader listing into the new one. *)
    let already_used =
      List.filter_map
        (fun entry ->
           let holds = List.exists (fun (tool : Agent_core.Tool.t) ->
             String.equal tool.schema.name entry.name) in
           if holds already_used || holds carried then Some entry.callable else None)
        entries
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
    let schema =
      match
        Agent_core.Types.tool_schema_of_input_schema
          ~name:tool_name
          ~description:(description_of entries)
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
    let held_schemas = Option.map (fun schemas -> schema :: schemas) held_schemas in
    let handler env input =
      let start_time = Tool_timing.start () in
      let outcome =
        match requested_names input with
      | Error message -> refusal message
      | Ok requested ->
        (match Agent_core.Tool.Execution_env.invocation env with
         | None ->
           Error
             { Agent_core.Types.message =
                 "this tool load has no execution identity for its continuation receipt"
             ; recoverable = false
             ; error_class = Some Agent_core.Types.Deterministic
             }
         | Some invocation ->
           load ~held_schemas ~keeper_name ~agent_cell ~entries ~usage ~receipts ~invocation requested)
      in
      (* task-3268: the search tool answers in agent-core types and bypasses
         the exec handler; mirror its honest outcome for the shared dispatch
         observers (#38824). The agent-core answer itself is unchanged. *)
      let metrics = metrics_result ~tool_name ~start_time outcome in
      Tool_dispatch.run_dispatch_observers Dispatch_outcome.Handled (Some metrics);
      outcome
    in
    Some
      { tool = Agent_core.Tool.of_schema schema handler
      ; already_used
      ; observe_turn = observe_turn ~keeper_name ~usage
      }
;;
