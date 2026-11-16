#include "include/NovelJavaScript.h"
#include "vendor/quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define NRJS_MEMORY_LIMIT (24 * 1024 * 1024)
#define NRJS_DATA_LIMIT (4 * 1024 * 1024)
#define NRJS_SCRIPT_LIMIT (256 * 1024)

typedef struct { double deadline; int interrupted; } NRJSBudget;
static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1000000000.0;
}
static int interrupt(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    NRJSBudget *budget = opaque;
    if (monotonic_seconds() < budget->deadline) return 0;
    budget->interrupted = 1;
    return 1;
}
static char *copy_string(const char *text) {
    size_t size = strlen(text) + 1;
    char *copy = malloc(size);
    if (copy) memcpy(copy, text, size);
    return copy;
}
static void capture_error(JSContext *context, NRJSResult *result, NRJSBudget *budget) {
    JSValue exception = JS_GetException(context);
    const char *message = JS_ToCString(context, exception);
    result->error = copy_string(budget->interrupted ? "JavaScript execution timed out" :
                                (message ? message : "JavaScript execution failed (memory or stack limit)"));
    result->timed_out = budget->interrupted;
    if (message) JS_FreeCString(context, message);
    JS_FreeValue(context, exception);
}
/* Legado scripts occur both as eval-style completion values and as a
   function body with top-level return. Compile first so a syntax fallback
   never executes a script twice or repeats side effects. */
static JSValue compile_rule(JSContext *context, const char *script) {
    JSValue compiled = JS_Eval(context, script, strlen(script), "book-source-rule.js",
                               JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    if (!JS_IsException(compiled)) return compiled;
    JSValue exception = JS_GetException(context);
    const char *message = JS_ToCString(context, exception);
    int has_return = message && strstr(message, "return");
    if (message) JS_FreeCString(context, message);
    if (!has_return) return JS_Throw(context, exception);
    JS_FreeValue(context, exception);
    const char *prefix = "(function(){\n";
    const char *suffix = "\n})()";
    size_t size = strlen(prefix) + strlen(script) + strlen(suffix) + 1;
    char *wrapped = malloc(size);
    if (!wrapped) return JS_ThrowOutOfMemory(context);
    strcpy(wrapped, prefix);
    strcat(wrapped, script);
    strcat(wrapped, suffix);
    compiled = JS_Eval(context, wrapped, strlen(wrapped), "book-source-rule.js",
                       JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    free(wrapped);
    return compiled;
}
NRJSResult NRJSEvaluate(const char *script, const char *globals_json, uint32_t timeout_ms) {
    NRJSResult result = {0};
    if (!script || !globals_json || strlen(script) > NRJS_SCRIPT_LIMIT || strlen(globals_json) > NRJS_DATA_LIMIT) {
        result.error = copy_string("JavaScript input exceeds size limit");
        return result;
    }
    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) { result.error = copy_string("Cannot create JavaScript runtime"); return result; }
    JS_SetMemoryLimit(runtime, NRJS_MEMORY_LIMIT);
    JS_SetMaxStackSize(runtime, 512 * 1024);
    JS_SetCanBlock(runtime, 0);
    NRJSBudget budget = {monotonic_seconds() + (timeout_ms ? timeout_ms : 250) / 1000.0, 0};
    JS_SetInterruptHandler(runtime, interrupt, &budget);
    JSContext *context = JS_NewContext(runtime);
    if (!context) {
        result.error = copy_string("Cannot create JavaScript context (memory limit)");
        JS_FreeRuntime(runtime);
        return result;
    }
    JSValue globals = JS_ParseJSON(context, globals_json, strlen(globals_json), "rule-context.json");
    JSValue global = JS_GetGlobalObject(context);
    JSPropertyEnum *properties = NULL;
    uint32_t count = 0;
    if (JS_IsException(globals) || JS_GetOwnPropertyNames(context, &properties, &count, globals,
                                                        JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) {
        capture_error(context, &result, &budget);
        goto cleanup;
    }
    for (uint32_t index = 0; index < count; index++) {
        JSValue value = JS_GetProperty(context, globals, properties[index].atom);
        if (JS_SetProperty(context, global, properties[index].atom, value) < 0) {
            capture_error(context, &result, &budget);
            goto cleanup;
        }
    }
    JSValue compiled = compile_rule(context, script);
    JSValue value = JS_IsException(compiled) ? compiled : JS_EvalFunction(context, compiled);
    if (JS_IsException(value)) {
        capture_error(context, &result, &budget);
    } else if (JS_IsPromise(value)) {
        result.error = copy_string("Asynchronous JavaScript rules are not supported");
    } else {
        // Undefined has no JSON representation; both undefined and null mean
        // no match to the rule pipeline, and must allow a fallback rule.
        JSValue json = JS_IsUndefined(value) ? JS_NewString(context, "null") :
            JS_JSONStringify(context, value, JS_UNDEFINED, JS_UNDEFINED);
        if (JS_IsException(json)) {
            capture_error(context, &result, &budget);
        } else if (JS_IsUndefined(json)) {
            result.error = copy_string("JavaScript rule must return a JSON-compatible value");
        } else {
            size_t length = 0;
            const char *text = JS_ToCStringLen(context, &length, json);
            if (!text) capture_error(context, &result, &budget);
            else if (length > NRJS_DATA_LIMIT) result.error = copy_string("JavaScript output exceeds size limit");
            else result.json = copy_string(text);
            if (text) JS_FreeCString(context, text);
        }
        JS_FreeValue(context, json);
    }
    JS_FreeValue(context, value);
cleanup:
    if (properties) {
        for (uint32_t index = 0; index < count; index++) JS_FreeAtom(context, properties[index].atom);
        js_free(context, properties);
    }
    JS_FreeValue(context, global);
    JS_FreeValue(context, globals);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    return result;
}
void NRJSFree(NRJSResult result) { free(result.json); free(result.error); }
