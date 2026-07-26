// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#include "adapter/seek_verifier.h"

#include <math.h>

MRASeekVerifier mra_seek_verifier_create(double requested) {
    return (MRASeekVerifier){
        .requested = requested,
        .lastExpected = requested,
        .verdict = MRASeekPending,
    };
}

void mra_seek_verifier_observe(MRASeekVerifier *verifier, bool hasSession,
                              bool hasReadback, double observed,
                              double elapsed, double playbackRate) {
    verifier->callbackCompleted = true;
    if (!hasSession) {
        return;
    }
    verifier->sawSession = true;
    if (!hasReadback) {
        return;
    }
    verifier->sawReadback = true;
    verifier->lastObserved = observed;
    verifier->lastExpected =
        verifier->requested + elapsed * playbackRate;
    if (fabs(verifier->lastObserved - verifier->lastExpected) <= 2.0) {
        verifier->verdict = MRASeekAccepted;
    }
}

MRASeekVerdict mra_seek_verifier_finish(MRASeekVerifier *verifier) {
    if (verifier->verdict == MRASeekAccepted) {
        return verifier->verdict;
    }
    if (!verifier->callbackCompleted) {
        return MRASeekTimedOut;
    }
    if (!verifier->sawSession) {
        return MRASeekNoSession;
    }
    if (!verifier->sawReadback) {
        return MRASeekUnavailable;
    }
    return MRASeekOutOfTolerance;
}
