#include "VorbisDecoder.h"

#define STB_VORBIS_NO_PUSHDATA_API
#include "stb_vorbis.c"

#include <stdlib.h>
#include <string.h>

int faugus_vorbis_decode_file(const char *path, FaugusVorbisPCM *pcm) {
    if (path == NULL || pcm == NULL) {
        return -1;
    }
    memset(pcm, 0, sizeof(*pcm));
    int channelCount = 0;
    int sampleRate = 0;
    short *samples = NULL;
    int frameCount = stb_vorbis_decode_filename(path, &channelCount, &sampleRate, &samples);
    if (frameCount < 0 || samples == NULL) {
        free(samples);
        return -1;
    }
    pcm->channelCount = channelCount;
    pcm->sampleRate = sampleRate;
    pcm->frameCount = frameCount;
    pcm->samples = samples;
    return 0;
}

void faugus_vorbis_free(FaugusVorbisPCM *pcm) {
    if (pcm == NULL) {
        return;
    }
    free(pcm->samples);
    pcm->samples = NULL;
    pcm->frameCount = 0;
    pcm->channelCount = 0;
    pcm->sampleRate = 0;
}
