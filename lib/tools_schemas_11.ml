(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_keeper_tool_catalog";
    description = "List visible server-side masc_* tools alongside keeper-internal wrapper coverage.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tier", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional tier filter: essential, standard, full");
        ]);
        ("include_hidden", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include hidden tools in the catalog");
        ]);
        ("include_deprecated", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include deprecated tools in the catalog");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max tools per page (default 50, max 500)");
        ]);
        ("offset", `Assoc [
          ("type", `String "integer");
          ("description", `String "Skip first N tools for pagination (default 0)");
        ]);
      ]);
    ];
  };
]
