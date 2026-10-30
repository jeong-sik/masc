(** Pure calendar and file-layout rules for the dated JSONL store. *)

val parse_date : string -> (string * string) option
(** [None] for malformed dates or days outside their calendar month. *)

val day_file_parts : string -> (string * int option) option
(** [Some (day, None)] is the current segment. [Some (day, Some sequence)]
    is a completed segment with its canonical positive decimal sequence.
    [None] means the filename is outside the segment grammar. *)

val compare_day_files : string -> string -> int
(** Oldest first; the current file follows its completed segments. Rotation
    sequences compare numerically, including the 999 to 1000 transition. *)

val day_number_of_day_file_name : string -> string
val year_and_month_of_directory_name : string -> (int * int) option
(** [None] for malformed names or months outside 1 through 12. *)

val month_directory_name_is_valid : string -> bool
val day_file_name_is_valid : year:int -> month:int -> string -> bool
val entry_is_foreign_to_layout : string -> bool
val rotated_segment_name : day_prefix:string -> sequence:int -> string
