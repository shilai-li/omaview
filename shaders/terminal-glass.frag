#version 440

// Puts a translucent window's glass back into its capture. Captures arrive
// opaque, which loses two kinds of see-through:
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
};

layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D backdrop;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    vec3 wall = texture(backdrop, qt_TexCoord0).rgb;
    vec3 base = c.rgb;
    if (keyGlass > 0.5) {
        vec3 key = background.rgb * alpha;
        vec3 glass = background.rgb * alpha + wall * (1.0 - alpha);
        float onKey = 1.0 - smoothstep(tolerance * 0.5, tolerance, distance(c.rgb, key));
        float onBlack = 1.0 - smoothstep(tolerance * 0.5, tolerance, length(c.rgb));
        base = mix(c.rgb, glass, max(onKey, onBlack));
    }
    fragColor = vec4(mix(wall, base, windowAlpha), 1.0) * qt_Opacity;
}
