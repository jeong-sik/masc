(** Byte-identity pins for the taskboard tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_shard_types.taskboard_tools] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    keeper_tasks_list builds its status enum from
    [Masc_domain.valid_task_status_strings] rather than a literal. A TOML
    literal would cut that derivation, so it stays in OCaml until it has a test
    pinning the file against its owner, the way
    [test_operator_surface_toml_parity] pins the masc_config category enum.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. *)

open Alcotest

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* name, description, input_schema (keys sorted) *)
let expected =
    [ {|keeper_tasks_list|}, {|List backlog tasks. Rows carry id, title, priority, created_at, status, assignee; projection=full adds description, files, contract, handoff_context, execution_links. awaiting_verification means the task awaits the completion-authority verdict and no Keeper can claim it; never Read producer sandbox paths. Rows are ordered by priority, then created_at, then id. When truncated is true the response carries next_cursor; pass it as cursor with the same status, include_done and projection to read the rows after that page. The last page has none.|}, {|{"properties":{"cursor":{"description":"Opaque next_cursor from a previous truncated keeper_tasks_list response. Pass it with the same status, include_done and projection to read the rows after that page. A cursor from a different filter, or one this tool did not issue, is rejected with field=cursor.","type":"string"},"if_revision":{"description":"Optional producer revision from the previous keeper_tasks_list snapshot; matching revisions return unchanged.","type":"string"},"include_done":{"description":"Include completed tasks (default: false)","type":"boolean"},"limit":{"default":50,"description":"Max tasks to return (default: 50)","maximum":100,"minimum":1,"type":"integer"},"projection":{"default":"compact","enum":["compact","full"],"type":"string"},"status":{"description":"Filter by task status","enum":["todo","claimed","in_progress","awaiting_verification","done","cancelled"],"type":"string"}},"type":"object"}|}
    ; {|keeper_tasks_audit|}, {|Find tasks whose exact assignee identity is absent from explicit active workspace/session membership. Returns the task status and assignee. This audit is read-only: it never releases or reassigns tasks.|}, {|{"properties":{"limit":{"default":20,"description":"Max orphans to return (default: 20)","maximum":50,"minimum":1,"type":"integer"}},"type":"object"}|}
    ; {|keeper_broadcast|}, {|Send a message visible to all agents in the MASC workspace. Use for status updates, announcements, or warnings.|}, {|{"properties":{"content":{"description":"Broadcast body text","minLength":1,"type":"string"},"task_cache_subject_agent":{"description":"Agent whose current-task cache was observed; supply together with task_cache_task_id","minLength":1,"type":"string"},"task_cache_task_id":{"description":"Task ID observed in the subject agent cache; supply together with task_cache_subject_agent","minLength":1,"type":"string"}},"required":["content"],"type":"object"}|}
    ; {|keeper_task_claim|}, {|Claim MASC backlog work. With no task_id, claims the next eligible unclaimed todo task that matches your capabilities. awaiting_verification tasks are pending a verdict from the system LLM agent at the completion-authority boundary and are not claimable Keeper work. Never Read producer sandbox paths directly. With task_id, claims that exact task when a user, mention, board item, or keeper_tasks_list row identifies it; an awaiting_verification task returns the typed pending-verdict refusal. If you already own another Claimed/InProgress task, finish it with keeper_task_done or hand it back with keeper_task_release first; keeper_task_claim does not auto-release active work.|}, {|{"properties":{"task_id":{"description":"Optional exact task id from keeper_tasks_list, board, mention, or user request","minLength":1,"type":"string"}},"type":"object"}|}
    ; {|keeper_task_done|}, {|Submit your claimed task for verification with a result summary and trusted evidence_refs. The task must be claimed by you. This does not make the task done: it moves to awaiting_verification and waits for a completion authority's verdict, which no Keeper can produce. It also does not hold your next claim while it waits. Every evidence_refs entry must be artifact:<producer-root-relative-path> or note:<text>; this tool refuses any other form at submit. Only an artifact: path is opened and snapshotted for the reviewer — a note: entry is text the reviewer reads but cannot inspect. Pure-placeholder results ('done', 'ok', etc.) are rejected.|}, {|{"properties":{"evidence_refs":{"description":"Trusted references substantiating completion. Every entry must be artifact:<producer-root-relative-path> or note:<text>; nothing else can be read back at review, so this tool refuses it here rather than letting the reviewer see missing evidence. An artifact: path is opened and snapshotted, and that is what satisfies the completion gate. A Board post id, a commit, a PR number, or a file:// URI is narrative until something opens it: pass it as note:<text> next to an artifact: entry, never on its own.","items":{"type":"string"},"minItems":1,"type":"array"},"notes":{"description":"Verification handoff notes (>= 20 chars). For contracted tasks: summarise what changed AND mention each contract.required_evidence entry verbatim. Ignored when the task has no contract.","type":"string"},"result":{"description":"What was done: files changed, tests run, outcome observed","minLength":1,"type":"string"},"task_id":{"description":"Task ID returned by keeper_task_claim","minLength":1,"type":"string"}},"required":["task_id","result","evidence_refs"],"type":"object"}|}
    ; {|keeper_task_release|}, {|Hand your claimed task back to the backlog so another Keeper can take it. Use this when you cannot finish the task and it should not sit with you: the work is blocked on something outside your reach, it needs a checkout or a tool you do not have, or your verification keeps coming back rejected. The task returns to the backlog with your summary attached, and you can claim different work immediately. This does not cancel the task and does not delete anything you already submitted. You must own the task.|}, {|{"properties":{"next_step":{"description":"What the next owner should do first.","type":"string"},"reason":{"description":"Why you are handing it back: what blocked you, or what you lack.","type":"string"},"summary":{"description":"Where the task stands right now, in one line. The next owner starts from this. Example: 'reproduced on the merged-cell table, fix not started'.","minLength":1,"type":"string"},"task_id":{"description":"Task ID you currently hold","minLength":1,"type":"string"}},"required":["task_id","summary"],"type":"object"}|}
    ; {|keeper_task_create|}, {|Create a new task on the MASC backlog. The task appears for any keeper to claim.|}, {|{"properties":{"contract":{"description":"Optional persisted task contract for deterministic completion and verification evidence.","properties":{"completion_contract":{"items":{"type":"string"},"type":"array"},"inspect_gate_evidence":{"items":{"type":"string"},"type":"array"},"required_evidence":{"items":{"type":"string"},"type":"array"},"strict":{"type":"boolean"},"verify_gate_evidence":{"items":{"type":"string"},"type":"array"}},"type":"object"},"description":{"description":"What to do, why, and acceptance criteria. Another keeper reads this to start working.","minLength":10,"type":"string"},"goal_id":{"description":"Optional structured goal linkage.","type":"string"},"priority":{"default":3,"description":"1=critical 2=high 3=medium 4=low 5=backlog","maximum":5,"minimum":1,"type":"integer"},"title":{"description":"Task title: verb + object + scope (e.g. 'Fix CI timeout in keeper_agent_run.ml')","maxLength":200,"minLength":5,"type":"string"}},"required":["title","description"],"type":"object"}|}
    ]
;;

let published = Tool_shard_types.taskboard_tools

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_shard_types.taskboard_tools")
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (find name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_shard_types.taskboard_tools in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

(* The condition the taskboard loader named for moving keeper_tasks_list out
   of OCaml. Its status enum used to be built from
   [Masc_domain.valid_task_status_strings] at schema-construction time, so a
   new task_status constructor reached the published schema on its own. A TOML
   literal cannot do that, and the failure it replaces is silent: the tool goes
   on advertising a status list that no longer names every status, and a filter
   for the missing one is refused at the boundary with nothing to point at.

   So the derivation becomes an assertion. The declaration is read back through
   the same loader the runtime uses, not from the file text, because that is
   the value the model is handed. *)
let test_status_enum_still_names_every_task_status () =
  let published =
    List.find
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name "keeper_tasks_list")
      Tool_shard_types.taskboard_tools
  in
  let declared =
    match published.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc properties) ->
         (match List.assoc_opt "status" properties with
          | Some (`Assoc status_fields) ->
            (match List.assoc_opt "enum" status_fields with
             | Some (`List values) ->
               List.map
                 (function
                   | `String value -> value
                   | other -> failf "status enum holds a non-string: %s"
                                (Yojson.Safe.to_string other))
                 values
             | _ -> fail "keeper_tasks_list status carries no enum")
          | _ -> fail "keeper_tasks_list publishes no status property")
       | _ -> fail "keeper_tasks_list publishes no properties")
    | _ -> fail "keeper_tasks_list input_schema is not an object"
  in
  check
    (list string)
    "config/tools/keeper_tasks_list.toml status enum vs \
     Masc_domain.valid_task_status_strings"
    Masc_domain.valid_task_status_strings
    declared
;;

let () =
  run
    "taskboard_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ; ( "derivation"
      , [ test_case
            "status enum names every task_status"
            `Quick
            test_status_enum_still_names_every_task_status
        ] )
    ]
;;
