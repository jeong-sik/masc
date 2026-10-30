(** Reading the two-set keyboard back out of a Hangul character.

    A terminal hands this program the text an input method produced, not the
    key the operator pressed. In Korean mode every letter key arrives as a
    Hangul character -- [j] as [ㅓ] -- while control keys, arrows and escape
    sequences pass the input method untouched and keep working. The command
    dispatch matches Latin spellings, so in Korean mode a letter shortcut
    arrived as a character no branch spells and died quietly.

    The two-set layout maps each letter key to exactly one Hangul letter, so
    the mapping reads back: this module turns a Hangul character into the
    Latin keys that produce it, in the order the operator pressed them. A
    composed syllable decomposes into its letters, because a terminal that
    composes before committing delivers [과] as one key event where the
    operator pressed three keys.

    This is a reading for command dispatch, not a text transformation. A
    field, the composer, or the chat surface taking characters as text keeps
    the Hangul it received; the caller decides which reading applies. Two
    limits are the input method's, not this table's. Shift does not survive
    it ([ㅓ] is both [j] and [J]), so tense letters read as their shifted
    spellings ([ㄲ] is [R]) and an ordinary uppercase shortcut stays out of
    reach in Korean mode. And the table spells the two-set layout alone; a
    three-set input method needs its own. *)

val latin_keys : string -> string list option
(** [latin_keys key] is [Some keys] when [key] is exactly one Hangul
    character the two-set layout can spell: the Latin keys that produce it,
    in typing order, each one character long. [None] when the key is
    anything else -- Latin already, a control character, a named key, a
    string that is not one character -- and the caller reads it as it
    stands. *)

val single_latin_key : string -> string option
(** Read back one two-set key without replaying a composed syllable or a
    compound letter as several commands. [None] leaves the original input
    unchanged. Intended for command-only panels with action shortcuts. *)
