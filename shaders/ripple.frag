#include <flutter/runtime_effect.glsl>

precision mediump float;


uniform float u_width;     // 0
uniform float u_height;    // 1
uniform float u_time;      // 2

uniform float u_tapX1;     // 3
uniform float u_tapY1;     // 4

uniform float u_tapX2;     // 5
uniform float u_tapY2;     // 6

uniform float u_tapX3;     // 7
uniform float u_tapY3;     // 8

uniform float u_tapX4;     // 9
uniform float u_tapY4;     // 10

uniform float u_tapX5;     // 11
uniform float u_tapY5;     // 12

uniform float u_tapTime1;  // 13
uniform float u_tapTime2;  // 14
uniform float u_tapTime3;  // 15
uniform float u_tapTime4;  // 16
uniform float u_tapTime5;  // 17

out vec4 fragColor;

float ripple(vec2 uv, vec2 center, float startTime) {
    float t = u_time - startTime;

    // kill ripple if too old
    if (t < 0.0 || t > 2.0) return 0.0;

    float d = distance(uv, center);

    // expanding wave
    float wave = sin(25.0 * d - t * 6.0);

    // thin line
    float lines = smoothstep(0.02, 0.0, abs(wave));

    // expanding ring effect
    float radius = t * 0.4;

    float ring = smoothstep(radius, radius - 0.02, d);

    // fade out over time
    float fade = exp(-1.5 * t);

    return lines * ring * fade;
}
void main() {
    vec2 uv = FlutterFragCoord().xy / vec2(u_width, u_height);

    float intensity = 0.0;

    intensity += ripple(uv, vec2(u_tapX1, u_tapY1), u_tapTime1);
    intensity += ripple(uv, vec2(u_tapX2, u_tapY2), u_tapTime2);
    intensity += ripple(uv, vec2(u_tapX3, u_tapY3), u_tapTime3);
    intensity += ripple(uv, vec2(u_tapX4, u_tapY4), u_tapTime4);
    intensity += ripple(uv, vec2(u_tapX5, u_tapY5), u_tapTime5);

    intensity = min(intensity, 1.0);
    intensity = pow(intensity, 0.7);

    vec3 color = vec3(0.7, 0.85, 1.0) * intensity;

    fragColor = vec4(color, 1.0);
}
