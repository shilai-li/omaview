#version 440

// Everything a window's picture needs, in the one pass its layer already
// costs: its rounded corners, and the glass a capture loses.
//
// Captures arrive opaque, which loses two kinds of see-through:
//
//  - A terminal's own background opacity: the background comes out as the
//    theme background at the terminal's opacity over black, a flat colour
//    that can be worked out rather than looked for. Where the capture shows
//    it, it is redrawn at that opacity over the blurred wallpaper behind the
//    window. Pure black, which is what lies outside the window's rounded
//    corners, becomes glass too. Everything else, text included, is kept.
//    (`keyGlass` on.)
//  - Hyprland's opacity on the whole window (a window rule, such as the one
//    Omarchy gives the file manager): everything, text included, is blended
//    over the wallpaper at `windowAlpha`.
//
// The wallpaper is read straight from the backdrop's own layer, at
// `backdropRect` (the part behind the window, in that texture's 0..1): a
// moving window only changes the numbers, never makes a copy.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 background;    // the theme background the terminal paints
    float alpha;        // the terminal's background opacity
    float tolerance;    // how far from the key colour still counts as background
    float keyGlass;     // 1 for a terminal's own see-through background
    float windowAlpha;  // Hyprland's opacity for the whole window
    float glass;        // 1 when the wallpaper shows through at all
    vec4 backdropRect;  // the part of the backdrop behind the window, 0..1
    vec2 size;          // the size the picture is shown at, logical pixels
    float radius;       // its corner radius, logical pixels
    float pixel;        // one device pixel, in logical pixels
};

layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D backdrop;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    vec4 color = c;
    if (glass > 0.5) {
        vec3 wall = texture(backdrop, backdropRect.xy + qt_TexCoord0 * backdropRect.zw).rgb;
        vec3 base = c.rgb;
        if (keyGlass > 0.5) {
            vec3 key = background.rgb * alpha;
            vec3 tint = background.rgb * alpha + wall * (1.0 - alpha);
            float onKey = 1.0 - smoothstep(tolerance * 0.5, tolerance, distance(c.rgb, key));
            float onBlack = 1.0 - smoothstep(tolerance * 0.5, tolerance, length(c.rgb));
            base = mix(c.rgb, tint, max(onKey, onBlack));
        }
        color = vec4(mix(wall, base, windowAlpha), 1.0);
    }
    float mask = 1.0;
    if (radius > 0.0) {
        vec2 half_ = size * 0.5;
        float r = min(radius, min(half_.x, half_.y));
        vec2 q = abs(qt_TexCoord0 * size - half_) - (half_ - vec2(r));
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        mask = clamp(0.5 - d / max(pixel, 0.0001), 0.0, 1.0);
    }
    fragColor = color * (mask * qt_Opacity);
}
