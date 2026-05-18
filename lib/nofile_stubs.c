#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/resource.h>
#endif

CAMLprim value masc_mcp_nofile_soft_limit(value unit)
{
  CAMLparam1(unit);
  CAMLlocal1(result);

#if defined(RLIMIT_NOFILE)
  struct rlimit limit;
  if (getrlimit(RLIMIT_NOFILE, &limit) != 0) {
    CAMLreturn(Val_int(0));
  }

  intnat soft_limit;
  if (limit.rlim_cur == RLIM_INFINITY || limit.rlim_cur > (rlim_t)Max_long) {
    soft_limit = Max_long;
  } else {
    soft_limit = (intnat)limit.rlim_cur;
  }

  result = caml_alloc(1, 0);
  Store_field(result, 0, Val_long(soft_limit));
  CAMLreturn(result);
#else
  CAMLreturn(Val_int(0));
#endif
}
