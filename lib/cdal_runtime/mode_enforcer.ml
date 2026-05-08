type tool_effect_class =
  | Read_only
  | Local_mutation
  | External_effect
  | Shell_dynamic

(* Backward-compatible alias. *)
type mutation_class = tool_effect_class

type violation_kind =
  | Mutating_in_diagnose
  | External_in_draft
  | Scope_violation

let violation_kind_to_string = function
  | Mutating_in_diagnose -> "mutating_in_diagnose"
  | External_in_draft -> "external_in_draft"
  | Scope_violation -> "scope_violation"
;;

let violation_kind_of_string = function
  | "mutating_in_diagnose" -> Ok Mutating_in_diagnose
  | "external_in_draft" -> Ok External_in_draft
  | "scope_violation" -> Ok Scope_violation
  | s -> Error (Printf.sprintf "unknown violation_kind: %s" s)
;;

let violation_kind_to_yojson v = `String (violation_kind_to_string v)

let violation_kind_of_yojson = function
  | `String s -> violation_kind_of_string s
  | j -> Error (Printf.sprintf "expected string, got %s" (Yojson.Safe.to_string j))
;;

type violation =
  { ts : float
  ; tool_name : string
  ; input_summary : string
  ; effective_mode : Execution_mode.t
  ; violation_kind : violation_kind
  }

let violation_to_yojson v =
  `Assoc
    [ "ts", `Float v.ts
    ; "tool_name", `String v.tool_name
    ; "input_summary", `String v.input_summary
    ; "effective_mode", Execution_mode.to_yojson v.effective_mode
    ; "violation_kind", violation_kind_to_yojson v.violation_kind
    ]
;;

let violation_of_yojson = function
  | `Assoc fields ->
    (match
       ( List.assoc_opt "ts" fields
       , List.assoc_opt "tool_name" fields
       , List.assoc_opt "input_summary" fields
       , List.assoc_opt "effective_mode" fields
       , List.assoc_opt "violation_kind" fields )
     with
     | ( Some (`Float ts)
       , Some (`String tool_name)
       , Some (`String input_summary)
       , Some mode_json
       , Some kind_json ) ->
       (match Execution_mode.of_yojson mode_json, violation_kind_of_yojson kind_json with
        | Ok effective_mode, Ok violation_kind ->
          Ok { ts; tool_name; input_summary; effective_mode; violation_kind }
        | Error e, _ | _, Error e -> Error e)
     | _ -> Error "missing or invalid fields in violation")
  | _ -> Error "violation: expected JSON object"
;;

type token_snapshot =
  { input_tokens : int
  ; output_tokens : int
  ; cost_usd : float option
  ; turn : int
  }

(* ── Tool classification registry ────────────────────────────────── *)

(** Default tool-id -> effect-class mappings. RFC-0005 §3.1 — keys are
    [Tool_id.t] poly-variant constructors so that adding a new built-in
    tool requires extending [Tool_id] and the compiler then flags every
    site that needs to acknowledge it. The runtime registry below stays
    string-keyed because plugin tools register at runtime by name. *)
let default_tool_entries : (Tool_id.t * tool_effect_class) list =
  [ (* ── Read-only tools ─────────────────────────────────────── *)
    (* File & code navigation *)
    `Read, Read_only
  ; `Glob, Read_only
  ; `Grep, Read_only
  ; `Search, Read_only
  ; `List_dir, Read_only
  ; `Find_file, Read_only
  ; `Read_file, Read_only
  ; `Find_symbol, Read_only
  ; `Get_symbols_overview, Read_only
  ; `Find_referencing_symbols, Read_only
  ; `Search_for_pattern, Read_only
  ; (* Notebook *)
    `Notebook_read, Read_only
  ; (* Browser observation *)
    `Read_console_messages, Read_only
  ; `Read_network_requests, Read_only
  ; `Get_page_text, Read_only
  ; `Read_page, Read_only
  ; `Tabs_context_mcp, Read_only
  ; (* Task queries *)
    `Task_list, Read_only
  ; `Task_get, Read_only
  ; `Task_output, Read_only
  ; (* ── Local-mutation tools ────────────────────────────────── *)
    (* File editing *)
    `Write, Local_mutation
  ; `Edit, Local_mutation
  ; `Create_text_file, Local_mutation
  ; `Replace_content, Local_mutation
  ; `Rename_symbol, Local_mutation
  ; `Insert_after_symbol, Local_mutation
  ; `Insert_before_symbol, Local_mutation
  ; `Replace_symbol_body, Local_mutation
  ; `Notebook_edit, Local_mutation
  ; (* Task & team management *)
    `Task_create, Local_mutation
  ; `Task_update, Local_mutation
  ; `Task_stop, Local_mutation
  ; `Team_create, Local_mutation
  ; `Team_delete, Local_mutation
  ; (* ── External-effect tools ───────────────────────────────── *)
    (* HITL *)
    `Ask_user_question, External_effect
  ; (* Web & research *)
    `Web_fetch, External_effect
  ; `Web_search, External_effect
  ; (* Browser interaction *)
    `Navigate, External_effect
  ; `Computer, External_effect
  ; `Find, External_effect
  ; `Form_input, External_effect
  ; `Javascript_tool, External_effect
  ; `Tabs_create_mcp, External_effect
  ; `Upload_image, External_effect
  ; (* ── Shell-dynamic tools (require input analysis at runtime) *)
    `Bash, Shell_dynamic
  ; `Execute_shell_command, Shell_dynamic
  ]
;;

(** Global mutable registry seeded from [default_tool_entries].
    Supports runtime extension via [register_tool_class].
    Keys are wire-format strings so plugin tools registered by name
    interoperate transparently with the typed defaults. *)
let tool_registry : (string, tool_effect_class) Hashtbl.t =
  let tbl = Hashtbl.create (List.length default_tool_entries) in
  List.iter
    (fun (id, cls) -> Hashtbl.replace tbl (Tool_id.to_string id) cls)
    default_tool_entries;
  tbl
;;

let register_tool_class name cls =
  Hashtbl.replace tool_registry (String.lowercase_ascii name) cls
;;

type state =
  { effective_mode : Execution_mode.t
  ; allowed_mutations : string list
  ; review_requirement : string option
  ; tool_classifications : (string * tool_effect_class) list
  ; mutable violations : violation list
  ; mutable token_snapshots : token_snapshot list
  ; mutable review_warning : string option
  ; mutable effect_evidence : Effect_evidence.t list
  }

let create ~contract ~effective_mode ?(tool_classifications = []) () =
  let rc = contract.Risk_contract.runtime_constraints in
  { effective_mode
  ; allowed_mutations = rc.allowed_mutations
  ; review_requirement = rc.review_requirement
  ; tool_classifications
  ; violations = []
  ; token_snapshots = []
  ; review_warning = None
  ; effect_evidence = []
  }
;;

let violations st = List.rev st.violations
let token_snapshots st = List.rev st.token_snapshots
let review_warning st = st.review_warning
let effect_evidence st = List.rev st.effect_evidence

(* ── Tool classification ─────────────────────────────────────────── *)

let classify_tool name =
  let key = String.lowercase_ascii name in
  match Hashtbl.find_opt tool_registry key with
  | Some cls -> cls
  | None ->
    (* Fail closed: MCP tools and anything unknown -> External_effect *)
    if String.length key > 5 && String.sub key 0 5 = "mcp__"
    then External_effect
    else External_effect
;;

(** Structured shell-command pattern entries.
    Each pair maps a substring pattern to the effect class it implies.
    Order does not matter -- [classify_bash_tool] checks external patterns
    first (fail closed) and falls back to mutating, then read-only. *)

type shell_pattern_entry =
  { pattern : string
  ; effect_class : tool_effect_class
  }

let shell_pattern_entries : shell_pattern_entry list =
  [ (* External-effect patterns (network, remote, deploy) *)
    { pattern = "curl "; effect_class = External_effect }
  ; { pattern = "wget "; effect_class = External_effect }
  ; { pattern = "ssh "; effect_class = External_effect }
  ; { pattern = "scp "; effect_class = External_effect }
  ; { pattern = "rsync "; effect_class = External_effect }
  ; { pattern = "git push"; effect_class = External_effect }
  ; { pattern = "git fetch"; effect_class = External_effect }
  ; { pattern = "git pull"; effect_class = External_effect }
  ; { pattern = "git clone"; effect_class = External_effect }
  ; { pattern = "docker "; effect_class = External_effect }
  ; { pattern = "kubectl "; effect_class = External_effect }
  ; { pattern = "helm "; effect_class = External_effect }
  ; { pattern = "npm publish"; effect_class = External_effect }
  ; { pattern = "pip install"; effect_class = External_effect }
  ; { pattern = "cargo publish"; effect_class = External_effect }
  ; { pattern = "systemctl "; effect_class = External_effect }
  ; { pattern = "launchctl "; effect_class = External_effect }
  ; (* Local-mutation patterns (filesystem, vcs local, package managers) *)
    { pattern = "rm "; effect_class = Local_mutation }
  ; { pattern = "rm\t"; effect_class = Local_mutation }
  ; { pattern = "rmdir "; effect_class = Local_mutation }
  ; { pattern = "mv "; effect_class = Local_mutation }
  ; { pattern = "cp "; effect_class = Local_mutation }
  ; { pattern = "mkdir "; effect_class = Local_mutation }
  ; { pattern = "touch "; effect_class = Local_mutation }
  ; { pattern = "chmod "; effect_class = Local_mutation }
  ; { pattern = "chown "; effect_class = Local_mutation }
  ; { pattern = "dd "; effect_class = Local_mutation }
  ; { pattern = "mkfs"; effect_class = Local_mutation }
  ; { pattern = "apt "; effect_class = Local_mutation }
  ; { pattern = "brew "; effect_class = Local_mutation }
  ; { pattern = "pip "; effect_class = Local_mutation }
  ; { pattern = "npm "; effect_class = Local_mutation }
  ; { pattern = "yarn "; effect_class = Local_mutation }
  ; { pattern = "cargo "; effect_class = Local_mutation }
  ; { pattern = "git commit"; effect_class = Local_mutation }
  ; { pattern = "git add"; effect_class = Local_mutation }
  ; { pattern = "git reset"; effect_class = Local_mutation }
  ; { pattern = "git rebase"; effect_class = Local_mutation }
  ; { pattern = "git merge"; effect_class = Local_mutation }
  ; { pattern = "git checkout"; effect_class = Local_mutation }
  ]
;;

(** Collect the highest-severity effect class from all matching patterns.
    External_effect > Local_mutation > Read_only. *)
let classify_shell_command cmd =
  let has_redirect = String.contains cmd '>' || Util.string_contains ~needle:"tee " cmd in
  let max_effect = ref Read_only in
  List.iter
    (fun entry ->
       if Util.string_contains ~needle:entry.pattern cmd
       then (
         match entry.effect_class, !max_effect with
         | External_effect, _ -> max_effect := External_effect
         | Local_mutation, Read_only -> max_effect := Local_mutation
         | _ -> ()))
    shell_pattern_entries;
  if has_redirect && !max_effect = Read_only then max_effect := Local_mutation;
  !max_effect
;;

let extract_bash_command (input : Yojson.Safe.t) =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "command" fields with
     | Some (`String cmd) -> Some (String.lowercase_ascii cmd)
     | _ -> None)
  | _ -> None
;;

let classify_bash_tool input =
  match extract_bash_command input with
  | None -> External_effect (* fail closed: unparseable -> external *)
  | Some cmd -> classify_shell_command cmd
;;

let effective_class tool_name input =
  match classify_tool tool_name with
  | Shell_dynamic -> classify_bash_tool input
  | c -> c
;;

let tool_effect_class_of_string = function
  | "read_only" -> Some Read_only
  | "workspace" | "workspace_mutating" | "local_mutation" -> Some Local_mutation
  | "external" | "external_effect" -> Some External_effect
  | "shell_dynamic" -> Some Shell_dynamic
  | _ -> None
;;

(* Backward-compatible alias *)
let mutation_class_of_string = tool_effect_class_of_string

(* ── Builtin descriptor derivation ─────────────────────────────── *)

let effect_class_to_mutation_class = function
  | Read_only -> "read_only"
  | Local_mutation -> "local_mutation"
  | External_effect -> "external_effect"
  | Shell_dynamic -> "external_effect"
;;

let effect_class_to_concurrency_class = function
  | Read_only -> Tool.Parallel_read
  | Local_mutation -> Tool.Sequential_workspace
  | External_effect | Shell_dynamic -> Tool.Exclusive_external
;;

let effect_class_to_permission = function
  | Read_only -> Tool.ReadOnly
  | Local_mutation -> Tool.Write
  | External_effect | Shell_dynamic -> Tool.Destructive
;;

let builtin_descriptor name : Tool.descriptor option =
  let key = String.lowercase_ascii name in
  match Hashtbl.find_opt tool_registry key with
  | None -> None
  | Some cls ->
    Some
      { Tool.kind = Some "builtin"
      ; mutation_class = Some (effect_class_to_mutation_class cls)
      ; concurrency_class = Some (effect_class_to_concurrency_class cls)
      ; permission = Some (effect_class_to_permission cls)
      ; shell =
          (if cls = Shell_dynamic
           then
             Some
               { single_command_only = false
               ; shell_metacharacters_allowed = true
               ; chaining_allowed = true
               ; redirection_allowed = true
               ; pipes_allowed = true
               ; workdir_policy = None
               }
           else None)
      ; notes = []
      ; examples = []
      }
;;

let effective_class_with_hints ~tool_classifications tool_name input =
  match List.assoc_opt tool_name tool_classifications with
  | Some cls -> cls
  | None -> effective_class tool_name input
;;

let all_read_only tools = List.for_all (fun name -> classify_tool name = Read_only) tools

let all_workspace_only tools =
  List.for_all
    (fun name ->
       match classify_tool name with
       | Read_only | Local_mutation -> true
       | External_effect | Shell_dynamic -> false)
    tools
;;

(* ── Enforcement check ───────────────────────────────────────────── *)

let truncate_input input = Util.clip (Yojson.Safe.to_string input) 200

let evidence_effect_class_of_tool_class = function
  | Read_only -> Effect_evidence.Read_only
  | Local_mutation -> Effect_evidence.Local_mutation
  | External_effect -> Effect_evidence.External_effect
  | Shell_dynamic -> Effect_evidence.Shell_dynamic
;;

let violation_kind_for_class st cls =
  match st.effective_mode, cls with
  | Execution_mode.Diagnose, (Local_mutation | External_effect) ->
    Some Mutating_in_diagnose
  | Execution_mode.Draft, External_effect -> Some External_in_draft
  | _ ->
    if List.mem "workspace_only" st.allowed_mutations && cls = External_effect
    then Some Scope_violation
    else None
;;

let record_effect_evidence
      st
      ~tool_use_id
      ~tool_name
      ~input
      ~turn
      ~ts
      ~effect_class
      ~decision
      ~result_status
      ?violation_kind
      ()
  =
  let violation_kind = Option.map violation_kind_to_string violation_kind in
  let row =
    Effect_evidence.make
      ~tool_use_id
      ~tool_name
      ~effect_class:(evidence_effect_class_of_tool_class effect_class)
      ~decision
      ~decision_source:"mode_enforcer"
      ~input
      ~input_summary:(truncate_input input)
      ~source_path:"lib/mode_enforcer.ml"
      ~source_line:__LINE__
      ~started_at:ts
      ~ended_at:ts
      ~result_status
      ?violation_kind
      ~turn
      ~execution_mode:(Execution_mode.to_string st.effective_mode)
      ()
  in
  st.effect_evidence <- row :: st.effect_evidence
;;

let check_violation st ~tool_use_id ~tool_name ~input ~turn =
  let ts = Unix.gettimeofday () in
  let cls =
    effective_class_with_hints
      ~tool_classifications:st.tool_classifications
      tool_name
      input
  in
  let kind = violation_kind_for_class st cls in
  match kind with
  | None ->
    record_effect_evidence
      st
      ~tool_use_id
      ~tool_name
      ~input
      ~turn
      ~ts
      ~effect_class:cls
      ~decision:Effect_evidence.Allowed
      ~result_status:Effect_evidence.Pending
      ();
    None
  | Some violation_kind ->
    let v =
      { ts
      ; tool_name
      ; input_summary = truncate_input input
      ; effective_mode = st.effective_mode
      ; violation_kind
      }
    in
    st.violations <- v :: st.violations;
    record_effect_evidence
      st
      ~tool_use_id
      ~tool_name
      ~input
      ~turn
      ~ts
      ~effect_class:cls
      ~decision:Effect_evidence.Denied
      ~result_status:Effect_evidence.Not_run
      ~violation_kind
      ();
    Some v
;;

(* ── Hooks ───────────────────────────────────────────────────────── *)

let hooks st =
  let open Hooks in
  { empty with
    before_turn =
      Some
        (fun event ->
          (match event with
           | BeforeTurn { turn = 1; _ } ->
             (match st.review_requirement, st.effective_mode with
              | Some req, Execution_mode.Execute ->
                st.review_warning
                <- Some
                     (Printf.sprintf
                        "review_requirement '%s' active but running in Execute mode"
                        req)
              | _ -> ())
           | _ -> ());
          Continue)
  ; pre_tool_use =
      Some
        (fun event ->
          match event with
          | PreToolUse { tool_use_id; tool_name; input; turn; _ } ->
            (match check_violation st ~tool_use_id ~tool_name ~input ~turn with
             | Some v ->
               Format.eprintf
                 "[mode_enforcer] SKIP tool=%s kind=%s mode=%s@."
                 tool_name
                 (violation_kind_to_string v.violation_kind)
                 (Execution_mode.to_string v.effective_mode);
               Skip
             | None -> Continue)
          | _ -> Continue)
  ; after_turn =
      Some
        (fun event ->
          (match event with
           | AfterTurn { turn; response; _ } ->
             (match response.Types.usage with
              | Some u ->
                let snap =
                  { input_tokens = u.input_tokens
                  ; output_tokens = u.output_tokens
                  ; cost_usd = u.cost_usd
                  ; turn
                  }
                in
                st.token_snapshots <- snap :: st.token_snapshots
              | None -> ())
           | _ -> ());
          Continue)
  }
;;

(* ── Inline tests ──────────────────────────────────────────────── *)
[@@@coverage off]

let%test "builtin_descriptor returns Some for read-only tools" =
  match builtin_descriptor "read" with
  | Some d ->
    d.mutation_class = Some "read_only"
    && d.concurrency_class = Some Tool.Parallel_read
    && d.permission = Some Tool.ReadOnly
  | None -> false
;;

let%test "builtin_descriptor returns Some for mutation tools" =
  match builtin_descriptor "edit" with
  | Some d ->
    d.mutation_class = Some "local_mutation"
    && d.concurrency_class = Some Tool.Sequential_workspace
    && d.permission = Some Tool.Write
  | None -> false
;;

let%test "builtin_descriptor returns Some for external tools" =
  match builtin_descriptor "web_fetch" with
  | Some d ->
    d.mutation_class = Some "external_effect"
    && d.concurrency_class = Some Tool.Exclusive_external
    && d.permission = Some Tool.Destructive
  | None -> false
;;

let%test "builtin_descriptor returns Some for ask_user_question" =
  match builtin_descriptor "ask_user_question" with
  | Some d -> d.concurrency_class = Some Tool.Exclusive_external
  | None -> false
;;

let%test "builtin_descriptor returns Some for task tools" =
  match builtin_descriptor "task_list" with
  | Some d -> d.concurrency_class = Some Tool.Parallel_read
  | None -> false
;;

let%test "builtin_descriptor returns Some for task_create" =
  match builtin_descriptor "task_create" with
  | Some d -> d.concurrency_class = Some Tool.Sequential_workspace
  | None -> false
;;

let%test "builtin_descriptor returns Some for shell tools" =
  match builtin_descriptor "bash" with
  | Some d -> d.mutation_class = Some "external_effect" && d.shell <> None
  | None -> false
;;

let%test "builtin_descriptor returns None for unknown tools" =
  builtin_descriptor "nonexistent_tool_xyz" = None
;;

let%test "register_tool_class extends registry" =
  register_tool_class "my_custom_tool" Read_only;
  match builtin_descriptor "my_custom_tool" with
  | Some d -> d.mutation_class = Some "read_only"
  | None -> false
;;
