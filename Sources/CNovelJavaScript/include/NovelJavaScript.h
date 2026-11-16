#ifndef NOVEL_JAVASCRIPT_H
#define NOVEL_JAVASCRIPT_H
#include <stdint.h>
typedef struct {
    char *json;
    char *error;
    int timed_out;
} NRJSResult;
/* Each call owns an isolated runtime. No libc, module loader, I/O or blocking
   Atomics API is installed. The caller releases both strings with NRJSFree. */
NRJSResult NRJSEvaluate(const char *script, const char *globals_json, uint32_t timeout_ms);
void NRJSFree(NRJSResult result);
#endif
