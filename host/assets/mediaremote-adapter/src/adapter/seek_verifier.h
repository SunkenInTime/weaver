// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#pragma once

#include <stdbool.h>

typedef enum {
    MRASeekPending,
    MRASeekAccepted,
    MRASeekTimedOut,
    MRASeekNoSession,
    MRASeekUnavailable,
    MRASeekOutOfTolerance,
} MRASeekVerdict;

typedef struct {
    double requested;
    bool callbackCompleted;
    bool sawSession;
    bool sawReadback;
    double lastObserved;
    double lastExpected;
    MRASeekVerdict verdict;
} MRASeekVerifier;

MRASeekVerifier mra_seek_verifier_create(double requested);
void mra_seek_verifier_observe(MRASeekVerifier *verifier, bool hasSession,
                              bool hasReadback, double observed,
                              double elapsed, double playbackRate);
MRASeekVerdict mra_seek_verifier_finish(MRASeekVerifier *verifier);
