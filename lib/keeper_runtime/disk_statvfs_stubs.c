#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/statvfs.h>
#endif

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>

static value make_error(const char *message)
{
  CAMLparam0();
  CAMLlocal2(v_msg, v_res);
  v_msg = caml_copy_string(message);
  v_res = caml_alloc(1, 1); /* Result.Error */
  Store_field(v_res, 0, v_msg);
  CAMLreturn(v_res);
}

#if defined(__unix__) || defined(__APPLE__)
static void format_errno_message(int err, char *buf, size_t len)
{
  if (len == 0) {
    return;
  }
  buf[0] = '\0';
#if defined(__GLIBC__) && defined(_GNU_SOURCE)
  /* GNU strerror_r returns char * and may point to static storage rather than buf. */
  const char *msg = strerror_r(err, buf, len);
  if (msg != NULL && msg != buf) {
    snprintf(buf, len, "%s", msg);
  } else if (msg == NULL || buf[0] == '\0') {
    snprintf(buf, len, "errno %d", err);
  }
#else
  if (strerror_r(err, buf, len) != 0 || buf[0] == '\0') {
    snprintf(buf, len, "errno %d", err);
  }
#endif
}

static int64_t mul_u64_clamped_i64(uint64_t a, uint64_t b)
{
  if (a == 0 || b == 0) {
    return 0;
  }
  if (a > (uint64_t)INT64_MAX / b) {
    return INT64_MAX;
  }
  return (int64_t)(a * b);
}
#endif

CAMLprim value caml_masc_statvfs(value v_path)
{
  CAMLparam1(v_path);
  CAMLlocal5(v_total, v_used, v_avail, v_tuple, v_result);

#if defined(__unix__) || defined(__APPLE__)
  const char *path = String_val(v_path);
  mlsize_t path_len = caml_string_length(v_path);
  if (memchr(path, '\0', (size_t)path_len) != NULL) {
    CAMLreturn(make_error("statvfs path contains embedded NUL byte"));
  }

  /* Copy the path off the OCaml heap and release the domain runtime lock
     before calling statvfs(2) so a hung NFS/FUSE mount cannot stall other
     fibers or threads in the same domain. */
  char *c_path = caml_stat_strdup(path);
  struct statvfs st;
  int rc;
  int saved_errno = 0;

  caml_enter_blocking_section();
  rc = statvfs(c_path, &st);
  if (rc != 0) {
    saved_errno = errno;
  }
  caml_leave_blocking_section();
  caml_stat_free(c_path);

  if (rc != 0) {
    char errbuf[256];
    format_errno_message(saved_errno, errbuf, sizeof(errbuf));
    CAMLreturn(make_error(errbuf));
  }

  uint64_t block_size = (uint64_t)st.f_frsize;
  if (block_size == 0) {
    block_size = (uint64_t)st.f_bsize;
  }
  if (block_size == 0) {
    CAMLreturn(make_error("statvfs reported zero block size"));
  }

  uint64_t total_blocks = (uint64_t)st.f_blocks;
  uint64_t free_blocks = (uint64_t)st.f_bfree;
  uint64_t avail_blocks = (uint64_t)st.f_bavail;
  uint64_t used_blocks =
    (total_blocks >= free_blocks) ? (total_blocks - free_blocks) : 0;

  int64_t total_bytes = mul_u64_clamped_i64(total_blocks, block_size);
  int64_t used_bytes = mul_u64_clamped_i64(used_blocks, block_size);
  int64_t avail_bytes = mul_u64_clamped_i64(avail_blocks, block_size);

  v_total = caml_copy_int64(total_bytes);
  v_used = caml_copy_int64(used_bytes);
  v_avail = caml_copy_int64(avail_bytes);

  v_tuple = caml_alloc_tuple(3);
  Store_field(v_tuple, 0, v_total);
  Store_field(v_tuple, 1, v_used);
  Store_field(v_tuple, 2, v_avail);

  v_result = caml_alloc(1, 0); /* Result.Ok */
  Store_field(v_result, 0, v_tuple);
  CAMLreturn(v_result);
#else
  CAMLreturn(make_error("statvfs is unavailable on this platform"));
#endif
}
