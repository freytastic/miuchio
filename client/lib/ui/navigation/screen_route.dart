import 'package:flutter/material.dart';

// Every full screen opens through this route. Its transition comes from
// Warm.theme, so going back is native on each platform: the edge swipe on
// iOS, and the back button and predictive back gesture on Android
Route<T> screenRoute<T>(Widget screen) =>
    MaterialPageRoute<T>(builder: (_) => screen);
