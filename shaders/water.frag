#include <flutter/runtime_effect.glsl>

precision highp float;

uniform float u_time;
uniform float u_width;
uniform float u_height;
uniform float progress;

out vec4 fragColor;

void main() {
    vec2 res = vec2(u_width, u_height);
    vec2 uv = FlutterFragCoord().xy / res;
    uv.y = 1.0 - uv.y;

    vec2 centered = uv - 0.5;
    float dist = length(centered);

    // circle mask
    float circle = smoothstep(0.5, 0.48, dist);

    float t = u_time;

    // clean soft surface wave only
    float wave =
        sin(uv.x * 8.0 + t * 1.2) * 0.010 +
        sin(uv.x * 14.0 - t * 0.9) * 0.006;

    float level = clamp(progress + wave, 0.0, 1.0);

    float waterVisible = step(0.01, progress);
    float fill = smoothstep(level, level - 0.018, uv.y) * waterVisible;

    // dark grey glass shell
    vec3 glassColor = vec3(0.045, 0.052, 0.060);

    float innerGlow = smoothstep(0.5, 0.0, dist);
    glassColor += vec3(0.08, 0.09, 0.10) * innerGlow;

    float rim = smoothstep(0.35, 0.5, dist);
    glassColor += vec3(0.35, 0.38, 0.42) * rim * 0.35;

    // smooth water color, no stripes
    vec3 bottomBlue = vec3(0.005, 0.035, 0.105);
    vec3 midBlue    = vec3(0.015, 0.145, 0.360);
    vec3 topBlue    = vec3(0.075, 0.430, 0.850);

    float depth = smoothstep(0.0, 1.0, uv.y);
    vec3 liquidColor = mix(bottomBlue, midBlue, depth);
    liquidColor = mix(liquidColor, topBlue, pow(depth, 2.0));

    // soft top water surface line only
    float surfaceLine =
        smoothstep(level + 0.012, level - 0.004, uv.y) *
        smoothstep(level - 0.035, level, uv.y);

    liquidColor += vec3(0.45, 0.75, 1.0) * surfaceLine * 0.38;

    // very soft edge light, not moving
    float edgeLight = smoothstep(0.45, 0.50, dist);
    liquidColor += vec3(0.12, 0.32, 0.55) * edgeLight * 0.25;

    vec3 finalColor = mix(glassColor, liquidColor, fill);

    fragColor = vec4(finalColor, circle);
}