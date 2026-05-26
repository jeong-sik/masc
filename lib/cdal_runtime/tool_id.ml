(* RFC-0005 Phase 1 §3.1 follow-up — typed tool identifier for the
   CDAL runtime's built-in classification table.

   Pattern reuses Agent_id.t (RFC-0005 Week 2, PR #14227): polymorphic
   variant with a fail-open `Other_tool of string` for runtime-registered
   plugin tools, paired with explicit to_string/of_string round-trip. *)

type t =
  [ `Workspace_inspect
  | `Glob
  | `Search
  | `List_dir
  | `Find_file
  | `Read_file
  | `Find_symbol
  | `Get_symbols_overview
  | `Find_referencing_symbols
  | `Search_for_pattern
  | `Notebook_read
  | `Read_console_messages
  | `Read_network_requests
  | `Get_page_text
  | `Read_page
  | `Tabs_context_mcp
  | `Task_list
  | `Task_get
  | `Task_output
  | `Write_file
  | `Edit_file
  | `Create_text_file
  | `Replace_content
  | `Rename_symbol
  | `Insert_after_symbol
  | `Insert_before_symbol
  | `Replace_symbol_body
  | `Notebook_edit
  | `Task_create
  | `Task_update
  | `Task_stop
  | `Team_create
  | `Team_delete
  | `Ask_user_question
  | `Fetch_web
  | `Search_web
  | `Navigate
  | `Computer
  | `Find
  | `Form_input
  | `Javascript_tool
  | `Tabs_create_mcp
  | `Upload_image
  | `Execute
  | `Execute_shell_command
  | `Other_tool of string
  ]

let to_string : t -> string = function
  | `Workspace_inspect -> "workspace_inspect"
  | `Glob -> "glob"
  | `Search -> "search"
  | `List_dir -> "list_dir"
  | `Find_file -> "find_file"
  | `Read_file -> "read_file"
  | `Find_symbol -> "find_symbol"
  | `Get_symbols_overview -> "get_symbols_overview"
  | `Find_referencing_symbols -> "find_referencing_symbols"
  | `Search_for_pattern -> "search_for_pattern"
  | `Notebook_read -> "notebook_read"
  | `Read_console_messages -> "read_console_messages"
  | `Read_network_requests -> "read_network_requests"
  | `Get_page_text -> "get_page_text"
  | `Read_page -> "read_page"
  | `Tabs_context_mcp -> "tabs_context_mcp"
  | `Task_list -> "task_list"
  | `Task_get -> "task_get"
  | `Task_output -> "task_output"
  | `Write_file -> "write_file"
  | `Edit_file -> "edit_file"
  | `Create_text_file -> "create_text_file"
  | `Replace_content -> "replace_content"
  | `Rename_symbol -> "rename_symbol"
  | `Insert_after_symbol -> "insert_after_symbol"
  | `Insert_before_symbol -> "insert_before_symbol"
  | `Replace_symbol_body -> "replace_symbol_body"
  | `Notebook_edit -> "notebook_edit"
  | `Task_create -> "task_create"
  | `Task_update -> "task_update"
  | `Task_stop -> "task_stop"
  | `Team_create -> "team_create"
  | `Team_delete -> "team_delete"
  | `Ask_user_question -> "ask_user_question"
  | `Fetch_web -> "fetch_web"
  | `Search_web -> "search_web"
  | `Navigate -> "navigate"
  | `Computer -> "computer"
  | `Find -> "find"
  | `Form_input -> "form_input"
  | `Javascript_tool -> "javascript_tool"
  | `Tabs_create_mcp -> "tabs_create_mcp"
  | `Upload_image -> "upload_image"
  | `Execute -> "execute"
  | `Execute_shell_command -> "execute_shell_command"
  | `Other_tool s -> s
;;

let of_string : string -> t = function
  | "workspace_inspect" | "workspaceinspect" -> `Workspace_inspect
  | "glob" -> `Glob
  | "search" -> `Search
  | "list_dir" -> `List_dir
  | "find_file" -> `Find_file
  | "read_file" | "readfile" -> `Read_file
  | "find_symbol" -> `Find_symbol
  | "get_symbols_overview" -> `Get_symbols_overview
  | "find_referencing_symbols" -> `Find_referencing_symbols
  | "search_for_pattern" -> `Search_for_pattern
  | "notebook_read" -> `Notebook_read
  | "read_console_messages" -> `Read_console_messages
  | "read_network_requests" -> `Read_network_requests
  | "get_page_text" -> `Get_page_text
  | "read_page" -> `Read_page
  | "tabs_context_mcp" -> `Tabs_context_mcp
  | "task_list" -> `Task_list
  | "task_get" -> `Task_get
  | "task_output" -> `Task_output
  | "write_file" | "writefile" -> `Write_file
  | "edit_file" | "editfile" -> `Edit_file
  | "create_text_file" -> `Create_text_file
  | "replace_content" -> `Replace_content
  | "rename_symbol" -> `Rename_symbol
  | "insert_after_symbol" -> `Insert_after_symbol
  | "insert_before_symbol" -> `Insert_before_symbol
  | "replace_symbol_body" -> `Replace_symbol_body
  | "notebook_edit" -> `Notebook_edit
  | "task_create" -> `Task_create
  | "task_update" -> `Task_update
  | "task_stop" -> `Task_stop
  | "team_create" -> `Team_create
  | "team_delete" -> `Team_delete
  | "ask_user_question" -> `Ask_user_question
  | "fetch_web" | "fetchweb" -> `Fetch_web
  | "search_web" | "searchweb" -> `Search_web
  | "navigate" -> `Navigate
  | "computer" -> `Computer
  | "find" -> `Find
  | "form_input" -> `Form_input
  | "javascript_tool" -> `Javascript_tool
  | "tabs_create_mcp" -> `Tabs_create_mcp
  | "upload_image" -> `Upload_image
  | "execute" -> `Execute
  | "execute_shell_command" -> `Execute_shell_command
  | other -> `Other_tool other
;;

let of_string_normalised s = s |> String.trim |> String.lowercase_ascii |> of_string

let known : t list =
  [ `Workspace_inspect
  ; `Glob
  ; `Search
  ; `List_dir
  ; `Find_file
  ; `Read_file
  ; `Find_symbol
  ; `Get_symbols_overview
  ; `Find_referencing_symbols
  ; `Search_for_pattern
  ; `Notebook_read
  ; `Read_console_messages
  ; `Read_network_requests
  ; `Get_page_text
  ; `Read_page
  ; `Tabs_context_mcp
  ; `Task_list
  ; `Task_get
  ; `Task_output
  ; `Write_file
  ; `Edit_file
  ; `Create_text_file
  ; `Replace_content
  ; `Rename_symbol
  ; `Insert_after_symbol
  ; `Insert_before_symbol
  ; `Replace_symbol_body
  ; `Notebook_edit
  ; `Task_create
  ; `Task_update
  ; `Task_stop
  ; `Team_create
  ; `Team_delete
  ; `Ask_user_question
  ; `Fetch_web
  ; `Search_web
  ; `Navigate
  ; `Computer
  ; `Find
  ; `Form_input
  ; `Javascript_tool
  ; `Tabs_create_mcp
  ; `Upload_image
  ; `Execute
  ; `Execute_shell_command
  ]
;;
