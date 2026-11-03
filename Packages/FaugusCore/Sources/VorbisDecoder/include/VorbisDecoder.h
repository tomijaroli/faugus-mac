#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Interleaved little-endian 16-bit PCM from an Ogg Vorbis file.
typedef struct FaugusVorbisPCM {
    int channelCount;
    int sampleRate;
    int frameCount;
    int16_t *samples;
} FaugusVorbisPCM;

/// 0 on success. `samples` is malloc'd; call `faugus_vorbis_free`.
int faugus_vorbis_decode_file(const char *path, FaugusVorbisPCM *pcm);
void faugus_vorbis_free(FaugusVorbisPCM *pcm);

#ifdef __cplusplus
}
#endif
