#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

static value rss_unavailable(const char *reason)
{
  CAMLparam0();
  CAMLlocal2(message, result);
  message = caml_copy_string(reason);
  result = caml_alloc(1, 1); /* Error */
  Store_field(result, 0, message);
  CAMLreturn(result);
}

CAMLprim value masc_process_resident_set(value unit)
{
  CAMLparam1(unit);
  CAMLlocal3(bytes, sample, result);
  uint64_t resident;
  int source;
#if defined(__APPLE__)
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  kern_return_t status = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                  (task_info_t)&info, &count);
  if (status != KERN_SUCCESS)
    CAMLreturn(rss_unavailable("Mach task_info resident memory probe failed"));
  resident = info.resident_size;
  source = 0; /* Process_memory.Mach_task_info */
#elif defined(__linux__)
  FILE *file = fopen("/proc/self/statm", "r");
  if (file == NULL)
    CAMLreturn(rss_unavailable("Linux process memory probe could not be opened"));
  unsigned long long virtual_pages, resident_pages;
  int fields = fscanf(file, "%llu %llu", &virtual_pages, &resident_pages);
  int close_status = fclose(file);
  long page_size = sysconf(_SC_PAGESIZE);
  if (fields != 2 || close_status != 0 || page_size <= 0)
    CAMLreturn(rss_unavailable("Linux process memory probe could not be read"));
  if (resident_pages > (uint64_t)INT64_MAX / (uint64_t)page_size)
    CAMLreturn(rss_unavailable("Linux resident memory measurement overflowed"));
  resident = (uint64_t)resident_pages * (uint64_t)page_size;
  source = 1; /* Process_memory.Proc_statm */
#else
  CAMLreturn(rss_unavailable("Resident memory probe is unavailable on this platform"));
#endif
  if (resident > INT64_MAX)
    CAMLreturn(rss_unavailable("Resident memory measurement overflowed"));
  bytes = caml_copy_int64((int64_t)resident);
  sample = caml_alloc_tuple(2); /* sample record, declaration order in .ml/.mli */
  Store_field(sample, 0, bytes);
  Store_field(sample, 1, Val_int(source));
  result = caml_alloc(1, 0); /* Ok */
  Store_field(result, 0, sample);
  CAMLreturn(result);
}
