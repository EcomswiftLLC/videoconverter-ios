#ifndef FLUXAFF_H
#define FLUXAFF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when this build includes the FFmpeg libraries, 0 when it was built without them.
int fx_available(void);

/// License line and version of the linked libraries (for the Licences screen and tests).
const char *fx_license(void);
const char *fx_configuration(void);
int fx_has_encoder(const char *name);
int fx_has_decoder(const char *name);
int fx_has_filter(const char *name);

/// A JSON document in the shape of `ffprobe -show_format -show_streams -of json`, or NULL when the file cannot be read.
/// Free it with fx_free.
char *fx_probe_json(const char *path);
void fx_free(void *pointer);

/// Called with the output time written so far (seconds) and the speed relative to real time (0 when unknown).
typedef void (*FxProgress)(double seconds, double speed, void *context);

/// Runs one conversion described with FFmpeg-style options (see FFmpegCommandBuilder.swift for the exact subset).
/// Blocks until it ends. Returns 0 on success, 1 when cancelled, a negative number on failure.
/// Set `*cancel` to a non-zero value from another thread to stop it.
int fx_execute(int argc, const char *const *argv, FxProgress progress, void *context, volatile int *cancel);

/// The last error FFmpeg reported on this thread's most recent run.
const char *fx_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
