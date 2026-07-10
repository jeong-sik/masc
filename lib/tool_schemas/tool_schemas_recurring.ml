(** Tool_schemas_recurring — SSOT for recurring task tool schemas.
    RFC-0314 — Keeper Recurring Producer. *)

open Masc_domain

let schemas : Masc_domain.tool_schema list = [
  (* masc_recurring_add *)
  {
    name = "masc_recurring_add";
    description = "Register a new recurring task for the calling keeper. \
Returns task id, label, interval_sec, and enabled status on success. \
Fails if a task with the same label already exists for this keeper.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("additionalProperties", `Bool false);
      ("properties", `Assoc [
        ("label", `Assoc [
          ("type", `String "string");
          ("description", `String "Short label for the recurring task (e.g. 'heartbeat-check').");
        ]);
        ("interval_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Interval in seconds between runs.");
        ]);
      ]);
      ("required", `List [`String "label"; `String "interval_sec"]);
    ];
  };

  (* masc_recurring_list *)
  {
    name = "masc_recurring_list";
    description = "List recurring tasks registered by the calling keeper. \
Returns task id, label, interval_sec, enabled status, last_run_ts, \
run_count, and failure_count for each task.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("additionalProperties", `Bool false);
      ("properties", `Assoc []);
    ];
  };

  (* masc_recurring_remove *)
  {
    name = "masc_recurring_remove";
    description = "Remove a recurring task by its ID. Only tasks belonging to \
the calling keeper can be removed. Returns success or not_found error.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("additionalProperties", `Bool false);
      ("properties", `Assoc [
        ("id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to remove (e.g. loop-12345-1).");
        ]);
      ]);
      ("required", `List [`String "id"]);
    ];
  };
]
