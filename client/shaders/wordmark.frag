#version 460 core

#include <flutter/runtime_effect.glsl>

// Reveals baked lettering where the pen has passed. The texture holds the
// antialiased lettering in red and the pen arrival time, 0 to 1, in green

uniform vec2 uSize;
uniform float uProgress;
// Soft pen front as a share of the whole word
uniform float uFront;
uniform vec4 uColor;
uniform sampler2D uMap;

out vec4 fragColor;

void main() {
  vec4 map = texture(uMap, FlutterFragCoord().xy / uSize);
  float head = uProgress * (1.0 + uFront);
  float shown = clamp((head - map.g) / uFront, 0.0, 1.0);
  float alpha = map.r * shown * uColor.a;
  fragColor = vec4(uColor.rgb * alpha, alpha);
}
