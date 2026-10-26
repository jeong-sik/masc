#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/epoll.h>
#include <sys/vfs.h>
#endif

struct group_handle {
  int parent, directory, events;
  dev_t device; ino_t inode;
  char *name;
};
#define Group_val(v) (*((struct group_handle **)Data_custom_val(v)))
static int close_handles(struct group_handle *g) {
  int fds[3]={g->events,g->directory,g->parent},error=0;
  g->events=-1;g->directory=-1;g->parent=-1;
  for(int i=0;i<3;i++) if(fds[i]>=0 && close(fds[i])<0 && !error) error=errno;
  return error;
}
static void finalize_group(value raw) {
  struct group_handle *g=Group_val(raw);
  if(g){close_handles(g);free(g->name);free(g);Group_val(raw)=NULL;}
}
static struct custom_operations operations={
  .identifier="masc.endpoint_process_group.v1", .finalize=finalize_group,
  .compare=custom_compare_default, .hash=custom_hash_default,
  .serialize=custom_serialize_default, .deserialize=custom_deserialize_default,
  .compare_ext=custom_compare_ext_default, .fixed_length=custom_fixed_length_default
};
/* malloc-backed storage remains stable while a worker releases the runtime
   lock. Each waiter owns a new open-file cursor, never a dup of group events. */
struct group_waiter { int events, watcher; };
#define Waiter_val(v) (*((struct group_waiter **)Data_custom_val(v)))
static int close_waiter(struct group_waiter *w) {
  int fds[2]={w->watcher,w->events},error=0;
  w->watcher=-1;w->events=-1;
  for(int i=0;i<2;i++) if(fds[i]>=0 && close(fds[i])<0 && !error) error=errno;
  return error;
}
static void finalize_waiter(value raw) {
  struct group_waiter *w=Waiter_val(raw);
  if(w){close_waiter(w);free(w);Waiter_val(raw)=NULL;}
}
static struct custom_operations waiter_operations={
  .identifier="masc.endpoint_process_group_waiter.v1", .finalize=finalize_waiter,
  .compare=custom_compare_default, .hash=custom_hash_default,
  .serialize=custom_serialize_default, .deserialize=custom_deserialize_default,
  .compare_ext=custom_compare_ext_default, .fixed_length=custom_fixed_length_default
};
static value error_option(int error) {
  CAMLparam0();CAMLlocal2(err,some);
  if(!error) CAMLreturn(Val_none);
  err=caml_unix_error_of_code(error);some=caml_alloc_small(1,0);Field(some,0)=err;
  CAMLreturn(some);
}
static value status(int stage,int error,int protection) {
  CAMLparam0();CAMLlocal2(result,err);err=error_option(error);
  result=caml_alloc_tuple(3);Field(result,0)=Val_int(stage);Field(result,1)=err;Field(result,2)=Val_int(protection);
  CAMLreturn(result);
}
#ifdef __linux__
/* All strings and the malloc-backed handle are private native copies before
   releasing the runtime lock. No pointer into the movable OCaml heap survives. */
static char *copy_string(value input) {
  size_t n=caml_string_length(input);char *copy=malloc(n+1);
  if(copy){memcpy(copy,String_val(input),n);copy[n]=0;}return copy;
}
static int private_directory(int fd,int private_) {
  struct stat st;
  if(fstat(fd,&st)<0) return -1;
  if(!S_ISDIR(st.st_mode) || st.st_uid!=0 || (st.st_mode & (private_?0077:0022))) return 0;
  return 1;
}
static int protected_parent(char *path,int *protection) {
  int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
  if(fd<0) return -1;
  char *save=NULL;
  for(char *part=strtok_r(path,"/",&save);part;part=strtok_r(NULL,"/",&save)) {
    int safe=private_directory(fd,0);
    if(safe!=1){if(safe==0)*protection=4;int error=errno;close(fd);errno=error;return -1;}
    if(!strcmp(part,".") || !strcmp(part,"..")){*protection=2;close(fd);return -1;}
    int next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
    int error=errno;close(fd);fd=next;errno=error;
    if(fd<0) return -1;
  }
  int safe=private_directory(fd,0);
  if(safe!=1){if(safe==0)*protection=4;int error=errno;close(fd);errno=error;return -1;}
  struct statfs fs;
  if(fstatfs(fd,&fs)<0){int error=errno;close(fd);errno=error;return -1;}
  if((unsigned long)fs.f_type!=0x63677270UL){*protection=5;close(fd);return -1;}
  return fd;
}
static int check_original(struct group_handle *g,int *protection) {
  int safe=private_directory(g->parent,0);
  if(safe!=1){if(safe==0)*protection=4;return -1;}
  safe=private_directory(g->directory,1);
  if(safe!=1){if(safe==0)*protection=7;return -1;}
  struct stat held,current;
  if(fstat(g->directory,&held)<0) return -1;
  if(fstatat(g->parent,g->name,&current,AT_SYMLINK_NOFOLLOW)<0) return -1;
  if(!S_ISDIR(current.st_mode) || held.st_nlink==0 || held.st_dev!=g->device
      || held.st_ino!=g->inode || current.st_dev!=g->device || current.st_ino!=g->inode) {
    *protection=6;return -1;
  }
  return 0;
}
static int read_events(int events,char **bytes,size_t *length) {
  if(lseek(events,0,SEEK_SET)<0)return errno;
  size_t capacity=0;
  for(;;) {
    if(*length==capacity){
      if(capacity>SIZE_MAX/2)return EOVERFLOW;
      size_t next=capacity?capacity*2:(size_t)getpagesize();
      char *grown=realloc(*bytes,next);if(!grown)return ENOMEM;
      *bytes=grown;capacity=next;
    }
    ssize_t count=read(events,*bytes+*length,capacity-*length);
    if(count<0){if(errno==EINTR)continue;return errno;}
    if(count==0)return 0;
    *length+=(size_t)count;
  }
}
#endif

CAMLprim value masc_endpoint_group_create(value path,value name) {
  CAMLparam2(path,name);CAMLlocal5(raw,result,error_value,cleanup_value,protection_value);
  raw=caml_alloc_custom(&operations,sizeof(struct group_handle *),0,1);Group_val(raw)=NULL;
  struct group_handle *g=calloc(1,sizeof(*g));
  int stage=1,error=0,protection=0,cleanup=0;
  if(!g) error=ENOMEM;
  else {
    g->parent=-1;g->directory=-1;g->events=-1;Group_val(raw)=g;
#ifdef __linux__
    char *parent_path=copy_string(path);g->name=copy_string(name);int created=0;
    if(!parent_path || !g->name) error=ENOMEM;
    if(!error) {
      caml_enter_blocking_section();
      if(geteuid()!=0) protection=1;
      if(!protection){stage=2;g->parent=protected_parent(parent_path,&protection);if(g->parent<0 && !protection)error=errno;}
      if(!error && !protection){stage=3;if(mkdirat(g->parent,g->name,0700)<0)error=errno;else created=1;}
      if(!error && !protection){stage=4;g->directory=openat(g->parent,g->name,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(g->directory<0)error=errno;}
      if(!error && !protection){
        struct stat st;
        if(fstat(g->directory,&st)<0)error=errno;
        else if(st.st_uid!=0 || !S_ISDIR(st.st_mode) || (st.st_mode&0077))protection=7;
        else {g->device=st.st_dev;g->inode=st.st_ino;}
      }
      if(!error && !protection){stage=5;g->events=openat(g->directory,"cgroup.events",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);if(g->events<0)error=errno;}
      /* Require the actual tree-kill interface before returning a usable group. */
      if(!error && !protection){stage=8;int fd=openat(g->directory,"cgroup.kill",O_WRONLY|O_CLOEXEC|O_NOFOLLOW);if(fd<0)error=errno;else close(fd);}
      if(error || protection) {
        if(created && unlinkat(g->parent,g->name,AT_REMOVEDIR)<0)cleanup=errno;
        int close_error=close_handles(g);if(!cleanup)cleanup=close_error;
      }
      caml_leave_blocking_section();
    }
    free(parent_path);
#else
    (void)path;(void)name;error=ENOSYS;
#endif
  }
  error_value=error_option(error);cleanup_value=error_option(cleanup);protection_value=Val_int(protection);
  result=caml_alloc_tuple(5);Field(result,0)=Val_int(stage);Field(result,1)=error_value;
  Field(result,2)=protection_value;Field(result,3)=cleanup_value;Field(result,4)=raw;
  CAMLreturn(result);
}
CAMLprim value masc_endpoint_group_read(value raw) {
  CAMLparam1(raw);CAMLlocal3(result,err,text);int error=0,protection=0;
  char *bytes=NULL;size_t length=0;
#ifdef __linux__
  struct group_handle *g=Group_val(raw);
  caml_enter_blocking_section();
  if(check_original(g,&protection)<0){if(!protection)error=errno;}
  if(!error && !protection)error=read_events(g->events,&bytes,&length);
  caml_leave_blocking_section();
#else
  (void)raw;error=ENOSYS;
#endif
  err=error_option(error);text=caml_alloc_initialized_string(length,bytes?bytes:"");free(bytes);
  result=caml_alloc_tuple(3);Field(result,0)=text;Field(result,1)=err;Field(result,2)=Val_int(protection);
  CAMLreturn(result);
}
CAMLprim value masc_endpoint_group_kill(value raw) {
  CAMLparam1(raw);int error=0,protection=0;
#ifdef __linux__
  struct group_handle *g=Group_val(raw);caml_enter_blocking_section();
  if(check_original(g,&protection)<0){if(!protection)error=errno;}
  if(!error && !protection){
    int fd=openat(g->directory,"cgroup.kill",O_WRONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0)error=errno;
    else {
      ssize_t count;do{count=write(fd,"1",1);}while(count<0 && errno==EINTR);
      if(count!=1)error=count<0?errno:EIO;
      if(close(fd)<0 && !error)error=errno;
    }
  }
  caml_leave_blocking_section();
#else
  (void)raw;error=ENOSYS;
#endif
  CAMLreturn(status(8,error,protection));
}
CAMLprim value masc_endpoint_group_remove(value raw) {
  CAMLparam1(raw);int error=0,protection=0;
#ifdef __linux__
  struct group_handle *g=Group_val(raw);caml_enter_blocking_section();
  if(check_original(g,&protection)<0){if(!protection)error=errno;}
  if(!error && !protection && unlinkat(g->parent,g->name,AT_REMOVEDIR)<0)error=errno;
  caml_leave_blocking_section();
#else
  (void)raw;error=ENOSYS;
#endif
  CAMLreturn(status(9,error,protection));
}
CAMLprim value masc_endpoint_group_directory(value raw) {
  CAMLparam1(raw);CAMLreturn(Val_int(Group_val(raw)->directory));
}
CAMLprim value masc_endpoint_group_waiter_create(value raw) {
  CAMLparam1(raw);CAMLlocal4(waiter,result,err,cleanup_value);
  waiter=caml_alloc_custom(&waiter_operations,sizeof(struct group_waiter *),0,1);Waiter_val(waiter)=NULL;
  struct group_waiter *w=malloc(sizeof(*w));
  int stage=1,error=0,protection=0,cleanup=0;
  if(!w)error=ENOMEM;
  else {
    w->events=-1;w->watcher=-1;Waiter_val(waiter)=w;
#ifdef __linux__
    struct group_handle *g=Group_val(raw);
    caml_enter_blocking_section();
    if(check_original(g,&protection)<0){if(!protection)error=errno;}
    if(!error && !protection){stage=5;w->events=openat(g->directory,"cgroup.events",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);if(w->events<0)error=errno;}
    if(!error && !protection){stage=6;w->watcher=epoll_create1(EPOLL_CLOEXEC);if(w->watcher<0)error=errno;}
    if(!error && !protection){
      struct epoll_event event;memset(&event,0,sizeof(event));event.events=EPOLLPRI|EPOLLERR;
      if(epoll_ctl(w->watcher,EPOLL_CTL_ADD,w->events,&event)<0)error=errno;
    }
    if(!error && !protection && check_original(g,&protection)<0){if(!protection)error=errno;}
    if(error || protection)cleanup=close_waiter(w);
    caml_leave_blocking_section();
#else
    error=ENOSYS;
#endif
  }
  err=error_option(error);cleanup_value=error_option(cleanup);result=caml_alloc_tuple(5);
  Field(result,0)=Val_int(stage);Field(result,1)=err;Field(result,2)=Val_int(protection);
  Field(result,3)=cleanup_value;Field(result,4)=waiter;
  CAMLreturn(result);
}
CAMLprim value masc_endpoint_group_waiter_read(value raw,value waiter) {
  CAMLparam2(raw,waiter);CAMLlocal3(result,err,text);
  int error=0,protection=0;char *bytes=NULL;size_t length=0;
#ifdef __linux__
  struct group_handle *g=Group_val(raw);struct group_waiter *w=Waiter_val(waiter);
  caml_enter_blocking_section();
  if(check_original(g,&protection)<0){if(!protection)error=errno;}
  if(!error && !protection)error=read_events(w->events,&bytes,&length);
  if(!error && !protection){
    /* Only this cursor acknowledges events. A transition after its read stays
       level-ready even when this private epoll queue is drained here. */
    struct epoll_event event;int rc;
    do{rc=epoll_wait(w->watcher,&event,1,0);}while(rc<0 && errno==EINTR);
    if(rc<0)error=errno;
  }
  caml_leave_blocking_section();
#else
  (void)raw;(void)waiter;error=ENOSYS;
#endif
  err=error_option(error);text=caml_alloc_initialized_string(length,bytes?bytes:"");free(bytes);
  result=caml_alloc_tuple(3);Field(result,0)=text;Field(result,1)=err;Field(result,2)=Val_int(protection);
  CAMLreturn(result);
}
CAMLprim value masc_endpoint_group_waiter_fd(value waiter) {
  CAMLparam1(waiter);CAMLreturn(Val_int(Waiter_val(waiter)->watcher));
}
CAMLprim value masc_endpoint_group_waiter_close(value waiter) {
  CAMLparam1(waiter);CAMLreturn(error_option(close_waiter(Waiter_val(waiter))));
}
CAMLprim value masc_endpoint_group_close(value raw) {
  CAMLparam1(raw);int error=close_handles(Group_val(raw));CAMLreturn(error_option(error));
}
