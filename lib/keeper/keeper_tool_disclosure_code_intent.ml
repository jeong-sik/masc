(** Keeper_tool_disclosure_code_intent — Code search/read/symbol intent detection.

    Extracted from [Keeper_tool_disclosure] during godfile decomposition.
    Case-insensitive substring matching for determining whether a user
    query intends to search, read, or inspect code symbols.

    @since God file decomposition *)

let contains_any_ci (text : string) (needles : string list) : bool =
  let haystack = String.lowercase_ascii text in
  List.exists
    (fun needle ->
       let needle = String.lowercase_ascii needle in
       let hay_len = String.length haystack in
       let needle_len = String.length needle in
       let rec loop idx =
         if needle_len = 0
         then true
         else if idx + needle_len > hay_len
         then false
         else if String.sub haystack idx needle_len = needle
         then true
         else loop (idx + 1)
       in
       loop 0)
    needles
;;

let code_context_needles =
  [ "code"
  ; "codebase"
  ; "source code"
  ; "source file"
  ; "repo"
  ; "repository"
  ; "symbol"
  ; "function"
  ; "class"
  ; "method"
  ; "module"
  ; "implementation"
  ; "snippet"
  ; "코드"
  ; "소스코드"
  ; "소스 파일"
  ; "심볼"
  ; "함수"
  ; "클래스"
  ; "모듈"
  ; "구현"
  ]
;;

let contains_code_path_hint (query_text : string) : bool =
  contains_any_ci
    query_text
    [ ".ml"
    ; ".mli"
    ; ".py"
    ; ".ts"
    ; ".tsx"
    ; ".js"
    ; ".jsx"
    ; ".rs"
    ; ".go"
    ; ".java"
    ; ".kt"
    ; ".c"
    ; ".cc"
    ; ".cpp"
    ; ".h"
    ; ".hpp"
    ; "lib/"
    ; "src/"
    ; "test/"
    ; "tests/"
    ; "app/"
    ; "bin/"
    ]
;;

let query_requests_code_search (query_text : string) : bool =
  let search_needles =
    [ "search"
    ; "find"
    ; "grep"
    ; "lookup"
    ; "query"
    ; "where is"
    ; "locate"
    ; "검색"
    ; "찾"
    ; "grep"
    ; "조회"
    ]
  in
  contains_any_ci query_text search_needles
  && contains_any_ci query_text code_context_needles
;;

let query_requests_code_read (query_text : string) : bool =
  let read_needles =
    [ "read"
    ; "view"
    ; "open"
    ; "inspect"
    ; "contents"
    ; "content"
    ; "implementation"
    ; "snippet"
    ; "cat"
    ; "읽"
    ; "열"
    ; "확인"
    ; "내용"
    ]
  in
  let read_context_needles =
    [ "source"
    ; "source code"
    ; "source file"
    ; "code"
    ; "function"
    ; "class"
    ; "method"
    ; "module"
    ; "implementation"
    ; "snippet"
    ; "line"
    ; "소스"
    ; "소스코드"
    ; "소스 파일"
    ; "코드"
    ; "함수"
    ; "클래스"
    ; "메서드"
    ; "모듈"
    ; "라인"
    ; "구현"
    ]
  in
  contains_any_ci query_text read_needles
  && (contains_any_ci query_text read_context_needles
      || contains_code_path_hint query_text)
;;

let query_requests_code_symbols (query_text : string) : bool =
  let symbol_needles =
    [ "symbol"
    ; "symbols"
    ; "function"
    ; "functions"
    ; "class"
    ; "classes"
    ; "method"
    ; "methods"
    ; "definition"
    ; "definitions"
    ; "outline"
    ; "structure"
    ; "api surface"
    ; "심볼"
    ; "함수"
    ; "클래스"
    ; "메서드"
    ; "정의"
    ; "구조"
    ]
  in
  contains_any_ci query_text symbol_needles
;;
