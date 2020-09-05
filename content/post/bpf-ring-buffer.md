+++
date        = "2020-09-05T00:03:00+02:00"
title       = "Using the BPF ring buffer"
description = "yo"
slug        = "bpf-ring-buffer-usage"
image       = "not-yet.jpg"
+++

# Introduction

The 5.8 release of the Linux Kernel came out with lots of interesting elements.

A couple of weeks ago, while still processing all the news in there, I came accross [a patch](0) proposing
a new bpf map type called `BPF_MAP_TYPE_RINGBUF`. By using this new map type
we finally have an MPSC (multi producer single consumer) data structure
optimized for data buffering and streaming.

Some exciting things about it:

- I'm not tied anymore to the same CPU when dealing with the output as I was with `BPF_MAP_TYPE_PERF_EVENT_ARRAY`. This is very important for me and I'm already experimenting with this in the [Falco](8) BPF driver.
- It's very flexible in letting me to decide what kind of memory allocation model I want to use by reserving beforehand or not.
- It is observable using `bpf_ringbuf_query` by replying to various queries about its  state. This could be useful to feed a prometheus exporter to monitor the health of the buffer.
- Producers do not block each other, even on different CPUs
- Spinlock is used internally to do the locking on reservations that are also ordered, while commits are completely lock free. This is very cool, because locking comes for free, no need to use `bpf_spin_lock` around or having to manage it.

The patch author did a very good job at explaining all the reasons why the change
was needed, so I will not go that way with this post. Instead, I want to write
about to actually make use of this new feature.

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

You can look at a complete list of all the BPF helpers at [bpf-helpers(7)](5).

With these premises, and to keep things simple I decided to show two different usage examples of the new features using libbpf and BCC.

It would be impractical for me to show you how to
use the functionalities in a *raw* way by defining ourselves all
the needed helpers definitions for the BPF functionalities we use.


# Using libbpf

Fortunately, the kernel provides a complete API that does all the work of exporting the helpers for us.

If you look around for libbpf, it has two homes:

- The original copy, resides in the linux kernel under [tools/lib/bpf](6).
- The out-of-tree mirror at [github.com/libbpf/libbpf](7).

To follow the example here, first go to the libbpf repository and follow the instructions to install it.
The ring buffer support was added in v0.0.9. Also, make sure to have a >= 5.8 Kernel.



# Using BCC

As always, the easiest way to get your hands into something new in the BPF world
is by trying [BCC](1) first.

BCC added the support for the BPF ring buffer almost immediately by [adding the helper definitions](2)
and by implementing [the Python API support](3).

To make this work you will need to be on a kernel >= 5.8 and have at least BCC 0.16.0.
If you need to learn how to install BCC they have a very good resource [here](4).

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

The python bcc module does not implement the `bpf_ring_query` helper so I was not
able to use that to show the current status of the buffer anywhere.

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
