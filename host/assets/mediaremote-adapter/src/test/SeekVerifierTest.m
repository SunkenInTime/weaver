// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#include "adapter/seek_verifier.h"

#include <assert.h>

int main(void) {
    MRASeekVerifier delayed = mra_seek_verifier_create(30.0);
    mra_seek_verifier_observe(&delayed, true, true, 5.0, 0.05, 2.0);
    assert(mra_seek_verifier_finish(&delayed) == MRASeekOutOfTolerance);
    mra_seek_verifier_observe(&delayed, true, true, 30.8, 0.4, 2.0);
    assert(mra_seek_verifier_finish(&delayed) == MRASeekAccepted);

    MRASeekVerifier noSession = mra_seek_verifier_create(30.0);
    mra_seek_verifier_observe(&noSession, false, false, 0, 0, 0);
    assert(mra_seek_verifier_finish(&noSession) == MRASeekNoSession);

    MRASeekVerifier timeout = mra_seek_verifier_create(30.0);
    assert(mra_seek_verifier_finish(&timeout) == MRASeekTimedOut);

    MRASeekVerifier outside = mra_seek_verifier_create(30.0);
    mra_seek_verifier_observe(&outside, true, true, 10.0, 1.0, 1.5);
    mra_seek_verifier_observe(&outside, true, true, 15.0, 1.9, 1.5);
    assert(mra_seek_verifier_finish(&outside) == MRASeekOutOfTolerance);
    return 0;
}
