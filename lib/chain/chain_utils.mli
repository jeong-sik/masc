(** Chain Utils - Safe Helper Functions

    Provides safe, exception-free alternatives to common OCaml stdlib functions.
*)

(** {1 Safe List Helpers} *)

val list_nth_opt : 'a list -> int -> 'a option
(** Safe version of List.nth - returns Option instead of raising Not_found *)

val list_hd_opt : 'a list -> 'a option
(** Safe version of List.hd - returns Option *)

val list_tl_safe : 'a list -> 'a list
(** Safe version of List.tl - returns empty list if input is empty *)

val list_uncons : 'a list -> ('a * 'a list) option
(** Safe head/tail split - returns None if list is empty *)

val list_last_opt : 'a list -> 'a option
(** Safe last element - O(n) but safe *)

(** {1 Safe String Helpers} *)

val starts_with : prefix:string -> string -> bool
(** Check if string starts with prefix *)

val ends_with : suffix:string -> string -> bool
(** Check if string ends with suffix *)

val string_sub_opt : string -> int -> int -> string option
(** Safe substring extraction - returns None if out of bounds *)

val truncate_with_ellipsis : ?max_len:int -> string -> string
(** Safe string truncation with ellipsis (default max_len=160) *)

val strip_prefix : prefix:string -> string -> string
(** Strip prefix if present, returns original string otherwise *)

val strip_suffix : suffix:string -> string -> string
(** Strip suffix if present, returns original string otherwise *)

(** {1 Empty Response Handling} *)

val max_empty_retries : int
(** Maximum retries for empty LLM responses *)

val is_empty_response : string -> bool
(** Check if response is empty or whitespace-only *)

val empty_retry_suffix : string
(** Enhancement prompt added on retry for empty responses *)

(** {1 Prompt Analysis Helpers} *)

val is_complex_prompt : string -> bool
(** Detect if a prompt is complex enough to benefit from thinking mode *)

val is_glm_model : string -> bool
(** Check if model is GLM variant *)

val string_contains : substring:string -> string -> bool
(** Check if string contains substring *)
