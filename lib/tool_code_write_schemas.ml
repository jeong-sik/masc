(* Tool schemas — cross-tool name references resolved through
   {!Tool_name.Operation} SSOT (RFC: agent-tool-design.md S10 P-S5)
   so description text stays in sync with the wire-name typed variant.
   Extracted from tool_code_write.ml during godfile decomposition. *)

let masc_code_write_name = Tool_name.Operation.to_string Tool_name.Operation.Code_write
let masc_code_edit_name = Tool_name.Operation.to_string Tool_name.Operation.Code_edit
let masc_code_read_name = Tool_name.Operation.to_string Tool_name.Operation.Code_read
let masc_code_delete_name = Tool_name.Operation.to_string Tool_name.Operation.Code_delete
let masc_code_shell_name = Tool_name.Operation.to_string Tool_name.Operation.Code_shell
let masc_code_git_name = Tool_name.Operation.to_string Tool_name.Operation.Code_git
let masc_worktree_create_name = Tool_name.Operation.to_string Tool_name.Operation.Worktree_create
let keeper_bash_name = Tool_name.Keeper.to_string Tool_name.Keeper.Bash

let schemas : Masc_domain.tool_schema list = [
  {
    name = masc_code_write_name;
    description = Printf.sprintf
      "Create or overwrite a file in an allowed coding sandbox \
       (.worktrees/ or .masc/playground/). \
       Use to generate new source files, configs, or replace entire file contents. \
       For partial edits (change a function, fix a line), use %s instead. \
       Returns bytes_written. Max 1MB. Set up a worktree first with %s."
      masc_code_edit_name
      masc_worktree_create_name;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to write (must be within .worktrees/ or .masc/playground/)");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "File content to write");
        ]);
        ("create_dirs", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Create intermediate directories if needed (default: false)");
          ("default", `Bool false);
        ]);
      ]);
      ("required", `List [`String "path"; `String "content"]);
    ];
  };

  {
    name = masc_code_edit_name;
    description = Printf.sprintf
      "Replace text in a file in an allowed coding sandbox \
       (.worktrees/ or .masc/playground/). \
       Use for surgical edits: fix a bug, update a function, change a config value. \
       old_string must match exactly once (unless replace_all=true). Returns replacement_count. \
       For full file replacement, use %s. Read the file first with %s \
       to get the exact text to replace."
      masc_code_write_name
      masc_code_read_name;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to edit (must be within .worktrees/ or .masc/playground/)");
        ]);
        ("old_string", `Assoc [
          ("type", `String "string");
          ("description", `String "Exact string to find and replace");
        ]);
        ("new_string", `Assoc [
          ("type", `String "string");
          ("description", `String "Replacement string");
        ]);
        ("replace_all", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Replace all occurrences (default: false, requires unique match)");
          ("default", `Bool false);
        ]);
      ]);
      ("required", `List [`String "path"; `String "old_string"; `String "new_string"]);
    ];
  };

  {
    name = masc_code_delete_name;
    description = "Delete a file in an allowed coding sandbox \
(.worktrees/ or .masc/playground/). Cannot delete directories. \
Use when removing generated, obsolete, or conflicting files during code work.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to delete (must be within .worktrees/ or .masc/playground/)");
        ]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };

  {
    name = masc_code_shell_name;
    description = Printf.sprintf
      "Run an allowlisted command in an allowed coding sandbox \
       (.worktrees/ or .masc/playground/). \
       Allowed: keeper dev-shell commands plus diff, patch, mkdir, ocamlfind, and tsc. \
       Use for building and testing code in isolated worktrees. \
       For unrestricted shell at project root, use %s. \
       Returns exit_code and stdout (truncated at %s)."
      keeper_bash_name
      Tool_code_write.max_output_label;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("command", `Assoc [
          ("type", `String "string");
          ("description", `String "Single shell command to run. Pipes are allowed only when every segment starts with an allowlisted command; chaining with ; or && is blocked.");
        ]);
        ("cwd", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory (must be within .worktrees/ or .masc/playground/)");
        ]);
        ("timeout", `Assoc [
          ("type", `String "integer");
          ("description", `String "Timeout in seconds (default: 30, max: 120)");
          ("default", `Int 30);
        ]);
      ]);
      ("required", `List [`String "command"]);
    ];
  };

  {
    name = masc_code_git_name;
    description = Printf.sprintf
      "Run git commands in an allowed coding sandbox \
       (.worktrees/ or .masc/playground/). Structured alternative \
       to %s for git operations. Supports: add, commit, push, diff, status, \
       log, branch, checkout, stash, fetch, clone. Force push and push to main/master are blocked. \
       Clone is restricted to allowed GitHub orgs (configured in config/tool_policy.toml). \
       Returns git command output."
      masc_code_shell_name;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          (* Issue #8522: derive from Variant SSOT — adding a new
             constructor flows through here automatically. *)
          ("enum", `List (List.map (fun s -> `String s) Tool_code_write.valid_git_action_strings));
          ("description", `String "Git action to perform");
        ]);
        ("args", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Additional git arguments");
        ]);
        ("cwd", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory (must be within .worktrees/ or .masc/playground/)");
        ]);
      ]);
      ("required", `List [`String "action"; `String "cwd"]);
    ];
  };
]

(** Tool names for keeper gating *)
let tool_names : string list =
  schemas |> List.map (fun (t : Masc_domain.tool_schema) -> t.name)

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_code_write
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ()))
    schemas
