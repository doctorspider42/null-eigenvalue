package com.nulleigenvalue.null_eigenvalue

import com.ryanheise.audioservice.AudioServiceActivity

// AudioServiceActivity rather than FlutterActivity: it is what binds the
// activity to the media session's Flutter engine, so a notification or a
// headphone button that arrives while the activity is gone still reaches the
// same isolate the UI is using.
class MainActivity : AudioServiceActivity()
