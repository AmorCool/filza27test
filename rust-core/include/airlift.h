// Airlift Rust core — C FFI surface.
//
// All fallible calls return an int32 code (0 == OK). Heap strings must be
// released with al_string_free().
#ifndef AIRLIFT_H
#define AIRLIFT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

// Receives every formatted log line. `msg` is only valid for the duration of
// the call — copy it. May be called from arbitrary Rust threads.
typedef void (*ALLogCallback)(void *ctx, const char *msg);

// Install the global tracing subscriber. Returns 0 on success, 1 if already
// initialised. Call once at launch.
int32_t al_log_init(ALLogCallback cb, void *ctx);

// Free any char* returned by this library.
void al_string_free(char *p);

// ---------------------------------------------------------------------------
// Pairing — RPPairing host
// ---------------------------------------------------------------------------

// Fires once the host is bound. The Swift side publishes `service_id` over
// Bonjour (NetService). All pointers are only valid during the call.
typedef void (*ALPairReadyCb)(void *ctx,
                               const char *service_id,
                               uint16_t port,
                               const char *const *txt_keys,
                               const char *const *txt_vals,
                               size_t txt_count);

// Fires with the PIN the user must confirm in Settings → Developer Mode.
typedef void (*ALPairPinCb)(const char *pin, void *ctx);

// Heap-allocated result of one pairing run. Free with al_pairing_result_free().
typedef struct {
    char *error;
    char *device_name;
    char *device_model;
    char *device_udid;
    char *pairing_file_path;
    char *host_alt_irk_hex;
} ALPairResult;

// Run the RPPairing host. BLOCKS until paired or errored — run off main thread.
// `port` 0 lets the OS pick a free port.
// `host_alt_irk_hex` is the value a previous run returned, or NULL/"" first time.
// Returns 0 on success, non-zero on error (with out->error set).
int32_t al_pairing_run_host(const char *bind_addr,
                             uint16_t port,
                             const char *name,
                             const char *model,
                             const char *out_path,
                             const char *host_alt_irk_hex,
                             ALPairReadyCb ready_cb,
                             ALPairPinCb pin_cb,
                             void *ctx,
                             ALPairResult *out);

// Free the heap strings inside an ALPairResult.
void al_pairing_result_free(ALPairResult *r);

// ---------------------------------------------------------------------------
// Exploit
// ---------------------------------------------------------------------------

// Run the AirTraffic sandbox escape. BLOCKS — run off the main thread.
// `pairing_path` — path produced by al_pairing_run_host.
// `target`       — absolute iOS directory (e.g. "/var/mobile/Library/SpringBoard").
// `log_cb`       — receives log lines (called from arbitrary threads; may be NULL).
// `out_json`     — set to a JSON result string; free with al_string_free().
// `out_error`    — set on failure; free with al_string_free().
// Returns 0 if the canary write was confirmed, 1 otherwise.
int32_t al_exploit_run(const char *pairing_path,
                        const char *target,
                        ALLogCallback log_cb,
                        void *ctx,
                        char **out_json,
                        char **out_error);

// Write all files from `source_dir` into `target_dir` on the device.
// Returns 0 on success, 1 on error (with out_error set).
int32_t al_exploit_write_dir(const char *pairing_path,
                             const char *source_dir,
                             const char *target_dir,
                             ALLogCallback log_cb,
                             void *ctx,
                             char **out_error);

// Pull `target_dir/leaf` into the LOCAL file `out_path`, then restore the file
// on-device (airlift-rw `extract_attempt` semantics). Blocking; run off the main
// thread. `out_json` is a heap JSON report (fine with al_string_free).
// Returns 0 on success (file pulled + restored), 1 on error.
int32_t al_exploit_read_file(const char *pairing_path,
                             const char *target_dir,
                             const char *leaf,
                             const char *out_path,
                             ALLogCallback log_cb,
                             void *ctx,
                             char **out_json,
                             char **out_error);

// Delete `target_dir/leaf` (moved into Media, recovered copy removed, no
// restore). `out_json` reports ok / targetAbsent / cleanupComplete.
int32_t al_exploit_remove(const char *pairing_path,
                          const char *target_dir,
                          const char *leaf,
                          ALLogCallback log_cb,
                          void *ctx,
                          char **out_json,
                          char **out_error);

// ---------------------------------------------------------------------------
// Syslog Stream / Live Card Detection
// ---------------------------------------------------------------------------

typedef void (*ALSyslogLineCallback)(void *ctx, const char *line);

// Stream device syslog messages over RSD.
// Blocks until al_syslog_stream_stop() is called.
int32_t al_syslog_stream_start(const char *pairing_path,
                               ALSyslogLineCallback line_cb,
                               void *ctx,
                               char **out_error);

// Stop any running syslog stream.
void al_syslog_stream_stop(void);

// Extract all files from a .passthm archive into dest_dir. Returns 0 on success.
int32_t al_passthm_extract(const char *archive_path, const char *dest_dir);


#ifdef __cplusplus
}
#endif

#endif /* AIRLIFT_H */
