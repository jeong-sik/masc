(** Tool_schemas_recurring — SSOT for recurring task tool schemas.
    RFC-0314 — Keeper Recurring Producer. *)

open Masc_domain

type operation =
  | Add
  | List
  | Remove

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

let operation_id = function
  | Add -> "add"
  | List -> "list"
  | Remove -> "remove"
;;

let definitions : definition list = [
  (* masc_recurring_add *)
  { operation = Add; read_only = false; schema = {
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
  } };

  (* masc_recurring_list *)
  { operation = List; read_only = true; schema = {
    name = "masc_recurring_list";
    description = "List recurring tasks registered by the calling keeper. \
Returns task id, label, interval_sec, enabled status, last_run_ts, \
run_count, and failure_count for each task.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("additionalProperties", `Bool false);
      ("properties", `Assoc []);
    ];
  } };

  (* masc_recurring_remove *)
  { operation = Remove; read_only = false; schema = {
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
  } };
]

let schemas = List.map (fun definition -> definition.schema) definitions
