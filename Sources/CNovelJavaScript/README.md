# Embedded JavaScript runtime

QuickJS-ng v0.11.0, commit `6a9fe9af5ca0bf7c49ae697edef44864272317d1`,
from https://github.com/quickjs-ng/quickjs, vendored unchanged in `vendor/`.
MIT license: `vendor/LICENSE`. Only the core interpreter is compiled; the CLI,
libc / OS bindings, module loading and worker examples are not included.

`NovelJavaScript.c` provides isolated JSON-in / JSON-out evaluation with a
250 ms default interrupt deadline, 24 MiB runtime memory limit, 512 KiB stack
limit, 256 KiB script limit and 4 MiB input/output limits. Blocking Atomics.wait
is disabled. Interrupted runtimes are discarded; no timed-out worker is left
running. There is no JIT or dependency on private Apple interruption APIs.
