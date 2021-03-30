+++
date        = "2020-09-08T00:17:00+02:00"
title       = "Using the BPF ring buffer"
description = "Usage of the new BPF_MAP_TYPE_RINGBUF bpf map type"
slug        = "bpf-ring-buffer-usage"
+++

Update March 30 2021:

This article is still relevant if you are looking for a practical example
on how to use the BPF Ring Buffer. If you want a deep explaination
on how it works I suggest to visit the blog of the main author
of this feature Andrii [here](https://nakryiko.com/posts/bpf-ringbuf/). Enjoy the learning! :)

# Introduction

The 5.8 release of the Linux Kernel came out with lots of interesting elements. Yes, as always.

A couple of weeks ago, while still processing all the news in there, I came accross [a patch][0] proposing
a new bpf map type called `BPF_MAP_TYPE_RINGBUF`. By using this new map type
we finally have an MPSC (multi producer single consumer) data structure
optimized for data buffering and streaming.

Some exciting things about it:

- This type of map is not tied to the same CPU when dealing with the output as it is with `BPF_MAP_TYPE_PERF_EVENT_ARRAY`. This is very important for me and I'm already experimenting with this in the [Falco][8] BPF driver.
- It's very flexible in letting the user to decide what kind of memory allocation model they want to use by reserving beforehand or not.
- It is observable using `bpf_ringbuf_query` by replying to various queries about its  state. This could be useful to feed a prometheus exporter to monitor the health of the buffer.
- Producers do not block each other, even on different CPUs
- Spinlock is used internally to do the locking on reservations that are also ordered, while commits are completely lock free. This is very cool, because locking comes for free, no need to use `bpf_spin_lock` around or having to manage it.

The patch author did a very good job at explaining all the reasons why the change
was needed, so I will not go that way with this post. Instead, I want to write
about to actually make use of this new feature.

# Motivation for this post

Finding good resources on new BPF features is very hard. The subsystem maintainers team is
doing a ginormous work at it and documenting every single bit is very difficult.

Moreover, this new feature is just another map interface so essentially
can be used as the others do. However, I felt like others could benefit
from my researching about this new features so i did put together this writeup
while I was experimenting on it.

# Note on helpers

For every functionality it exposes, the BPF subsystem exposes an helper.

The helper is used to let you interact with that specific part of the subsystem
that does the feature you are invoking.

The purpose of the Linux Kernel is not to give you the helper definitions
or a library so your system will normally not ship with an header that you can
import to get your hands into the functions definitions for the helper.

The idea is that you will write the definitions yourself when you want to use a specific helper, e.g:

```
static void *(*bpf_ringbuf_reserve)(void *ringbuf, __u64 size, __u64 flags) =
  (void *)BPF_FUNC_ringbuf_reserve;
```


The patch adds 5 new BPF helpers

```
void *bpf_ringbuf_output(void *ringbuf, void *data, u64 size, u64 flags);
void *bpf_ringbuf_reserve(void *ringbuf, u64 size, u64 flags);
void bpf_ringbuf_submit(void *data, u64 flags);
void bpf_ringbuf_discard(void *data, u64 flags);
u64 bpf_ringbuf_query(void *ringbuf, u64 flags);
```

You can look at a complete list of all the BPF helpers at [bpf-helpers(7)][5].

With these premises, and to keep things simple I decided to show two different usage examples of the new features using libbpf and BCC.

It would be impractical for me to show you how to
use the functionalities in a *raw* way by defining ourselves all
the needed helpers definitions for the BPF functionalities we use.

A very good explaination about BPF helpers can be found at [ebpf.io][9].

# Using libbpf

Fortunately, the kernel provides a complete API that does all the work of exporting the helpers for us.

If you look around for libbpf, it has two homes:

- The original copy, resides in the linux kernel under [tools/lib/bpf][6].
- The out-of-tree mirror at [github.com/libbpf/libbpf][7].

To follow the example here, first go to the libbpf repository and follow the instructions to install it.
The ring buffer support was added in v0.0.9. Also, make sure to have a >= 5.8 Kernel.

Here is how the BPF program:

The program itself is very simple, we attach to the tracepoint that gets hit
every time an `execve` syscall is done.

The interesting part here for `BPF_MAP_TYPE_RINGBUF` is the initialization
of the map with `bpf_map_def`. This type of map does not want the `.key` and `.value` sections
and for the `.max_entries` value the patch says it wants a power of two. That is
not entirely right, the value also needs to be page aligned with the current page shift size.
In the current `asm_generic/page.h` [here][10] it's defined as `1 << 12` so any value multiple of 4096 will be ok.

Once the map is initialized, look at what we do in our tracepoint, there are two ringbuf specific calls:

- `bpf_ringbuf_reserve` does the memory reservation for the buffer, this is the only time locking is done
- `bpf_ringbuf_submit` does the actual write to the map, this is lock free

```c
#include <linux/types.h>

#include <bpf/bpf_helpers.h>
#include <linux/bpf.h>

struct event {
  __u32 pid;
  char filename[16];
};

struct bpf_map_def SEC("maps") buffer = {
    .type = BPF_MAP_TYPE_RINGBUF,
    .max_entries = 4096 * 64,
};

struct trace_entry {
  short unsigned int type;
  unsigned char flags;
  unsigned char preempt_count;
  int pid;
};

struct trace_event_raw_sys_enter {
  struct trace_entry ent;
  long int id;
  long unsigned int args[6];
  char __data[0];
};


SEC("tracepoint/syscalls/sys_enter_execve")
int sys_enter_execve(struct trace_event_raw_sys_enter *ctx) {
  __u32 pid = bpf_get_current_pid_tgid();
  struct event *event = bpf_ringbuf_reserve(&buffer, sizeof(struct event), 0);
  if (!event) {
    return 1;
  }
  event->pid = pid;
  bpf_probe_read_user_str(event->filename, sizeof(event->filename),
                          (const char *)ctx->args[0]);

  bpf_ringbuf_submit(event, 0);

  return 0;
}

char _license[] SEC("license") = "GPL";
```
Now save this source in a file called `program.c` if you want to try it later.

Loading the program would be impossible without a loader.

Besides all the boilerplate it does to load the program and the tracepoint,
there are some interesting things for the ringbuf usecase here too:

- The `buf_process_sample` callback gets called every time a new element is read from the ring buffer
- The ringbuffer is read using `ring_buffer_consume`

```c
#include <bpf/libbpf.h>
#include <stdio.h>
#include <unistd.h>

struct event {
  __u32 pid;
  char filename[16];
};

static int buf_process_sample(void *ctx, void *data, size_t len) {
  struct event *evt = (struct event *)data;
  printf("%d %s\n", evt->pid, evt->filename);

  return 0;
}

int main(int argc, char *argv[]) {
  const char *file = "program.o";
  struct bpf_object *obj;
  int prog_fd = -1;
  int buffer_map_fd = -1;
  struct  bpf_program *prog;

  bpf_prog_load(file, BPF_PROG_TYPE_TRACEPOINT, &obj, &prog_fd);

  struct bpf_map *buffer_map;
  buffer_map_fd = bpf_object__find_map_fd_by_name(obj, "buffer");

  struct ring_buffer *ring_buffer;
 
  ring_buffer = ring_buffer__new(buffer_map_fd, buf_process_sample, NULL, NULL);

  if(!ring_buffer) {
    fprintf(stderr, "failed to create ring buffer\n");
    return 1;
  }

	prog = bpf_object__find_program_by_title(obj, "tracepoint/syscalls/sys_enter_execve");
	if (!prog) {
    fprintf(stderr, "failed to find tracepoint\n");
    return 1;
	}

  bpf_program__attach_tracepoint(prog, "syscalls", "sys_enter_execve");

  while(1) {
    ring_buffer__consume(ring_buffer);
    sleep(1);
  }

  return 0;
}
```

Now save this source in a file called `loader.c` if you want to try it later.

It required quite some code to just showcase the ringbuf related functions.
Sorry for the big wall of code!

Now we can proceed, compile and run it.

In the folder where you saved `program.c` and `loader.c`:

Compile the program:

```bash
clang -O2 -target bpf -g -c program.c # -g is to generate btf code
```

Compile the loader
```
gcc -g -lbpf loader.c
```

You can now run it via:

```
sudo ./a.out
```

It wil produce something similar to this:


```bash
393811 /bin/zsh
393812 /usr/bin/env
393812 /usr/local/bin/
393812 /usr/local/sbin
393812 /usr/bin/zsh
393816 /usr/bin/ls
393818 /usr/bin/git
393819 /usr/bin/awk
393824 /usr/bin/git
393825 /usr/bin/git
393826 /usr/bin/git
```

If you followed my suggestion and left the `-g` flag
to the `clang` command while compiling the program, congrats, you just produced a BPF CO-RE (Compile Once, Run Everywhere) program.

Yes, you can move it to another machine with Kernel 5.8 and it will work. Next step is to compile the loader statically to move it
together with the program. This is left to the reader :)

# Using BCC

This paragraph is about doing the same thing we did with libbpf but with [BCC][1].

BCC added the support for the BPF ring buffer almost immediately by [adding the helper definitions][2]
and by implementing [the Python API support][3].

To make this work you will need to be on a kernel >= 5.8 and have at least BCC 0.16.0.
If you need to learn how to install BCC they have a very good resource [here][4].

Here's the python code, comments below:

```python
#!/usr/bin/python3

import sys
import time

from bcc import BPF

src = r"""
BPF_RINGBUF_OUTPUT(buffer, 1 << 4);

struct event {
    u32 pid;
    char filename[16];
};

TRACEPOINT_PROBE(syscalls, sys_enter_execve) {
    u32 pid = bpf_get_current_pid_tgid();
    struct event *event = buffer.ringbuf_reserve(sizeof(struct event));
    if (!event) {
        return 1;
    }
    event->pid = pid;
    bpf_probe_read_user_str(event->filename, sizeof(event->filename), args->filename);

    buffer.ringbuf_submit(event, 0);

    return 0;
}
"""

b = BPF(text=src)

def callback(ctx, data, size):
    event = b['buffer'].event(data)
    print("%-8s %-16s" % (event.pid, event.filename.decode('utf-8')))


my_rb = b['buffer']
my_rb.open_ring_buffer(callback)

print("%-8s %-16s" % ("PID", "FILENAME"))

try:
    while 1:
        b.ring_buffer_poll()
        time.sleep(0.5)
except KeyboardInterrupt:
    sys.exit()
```

As you can see, we are making use of the BCC helper `BPF_RINGBUF_OUTPUT` to
create a ring buffer named `events`, then on that one we call `ringbuf_submit` and `ringbug_poll`
to do our read and write operations. 

If you want to try, copy the program to a `program.py` file.
You will need to execute it with root permissions:

```
sudo python program.py
```

The output should be something like:
```
PID      FILENAME
43674    /bin/zsh
43675    /usr/bin/env
43675    /usr/local/bin/
43675    /usr/local/sbin
43675    /usr/bin/zsh
43678    /usr/bin/dircol
43679    /usr/bin/ls
43681    /usr/bin/git
43682    /usr/bin/awk
43687    /usr/bin/git
43688    /usr/bin/git
43689    /usr/bin/git
43701    /usr/bin/sh
43701    /usr/bin/git
```

# Conclusions

Once again, as with every release, the BPF subsystem is becoming more
and more feature complete. This specific feature is addressing a 
very felt use case for those (like me) who move a lot of data around using maps.

Thanks to the maintainers and the many contributors for their hard work!


[0]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=457f44363a8894135c85b7a9afd2bd8196db24ab
[1]: https://github.com/iovisor/bcc
[2]: https://github.com/iovisor/bcc/pull/2969
[3]: https://github.com/iovisor/bcc/pull/2989
[4]: https://github.com/iovisor/bcc/blob/master/INSTALL.md
[5]: https://man7.org/linux/man-pages/man7/bpf-helpers.7.html#IMPLEMENTATION
[6]: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/tools/lib/bpf?h=v5.8.6
[7]: https://github.com/libbpf/libbpf
[8]: https://github.com/falcosecurity/falco
[9]: https://ebpf.io/what-is-ebpf#helper-calls
[10]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/asm-generic/page.h?id=457f44363a8894135c85b7a9afd2bd8196db24ab#n18
