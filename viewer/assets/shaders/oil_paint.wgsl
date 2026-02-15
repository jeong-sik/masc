// Oil painting post-processing shader for 그림란드 연대기
// Combines: Kuwahara filter + Sobel edge + Color grading + Vignette/grain
// Single-pass for performance (no intermediate textures needed).

#import bevy_core_pipeline::fullscreen_vertex_shader::FullscreenVertexOutput

@group(0) @binding(0) var screen_texture: texture_2d<f32>;
@group(0) @binding(1) var texture_sampler: sampler;
@group(0) @binding(2) var<uniform> settings: PostProcessSettings;

struct PostProcessSettings {
    // Kuwahara
    kuwahara_radius: f32,
    // Edge detection
    edge_strength: f32,
    // Color grading
    saturation: f32,
    warmth: f32,
    // Vignette
    vignette_strength: f32,
    // Grain
    grain_strength: f32,
    // Time (for animated grain)
    time: f32,
    // Master intensity (0 = no effect, 1 = full effect)
    intensity: f32,
}

// ─── Kuwahara Filter (Isotropic, 4-sector) ───────────────────
// Divides neighborhood into 4 overlapping quadrants.
// For each quadrant: compute mean color and variance.
// Output the mean of the quadrant with lowest variance.
// This produces the characteristic "flat brushstroke" look.

fn kuwahara(uv: vec2<f32>, texel_size: vec2<f32>, radius: i32) -> vec3<f32> {
    var mean: array<vec3<f32>, 4>;
    var variance: array<f32, 4>;

    // Initialize accumulators
    for (var k = 0; k < 4; k++) {
        mean[k] = vec3<f32>(0.0);
        variance[k] = 0.0;
    }

    // Sector sample ranges (overlapping quadrants)
    // Sector 0: top-left,     Sector 1: top-right
    // Sector 2: bottom-left,  Sector 3: bottom-right
    let ranges = array<vec4<i32>, 4>(
        vec4<i32>(-radius, 0, -radius, 0),  // x_min, x_max, y_min, y_max
        vec4<i32>(0, radius, -radius, 0),
        vec4<i32>(-radius, 0, 0, radius),
        vec4<i32>(0, radius, 0, radius),
    );

    for (var k = 0; k < 4; k++) {
        var sum = vec3<f32>(0.0);
        var sum_sq = vec3<f32>(0.0);
        var count = 0.0;

        let r = ranges[k];
        for (var x = r.x; x <= r.y; x++) {
            for (var y = r.z; y <= r.w; y++) {
                let offset = vec2<f32>(f32(x), f32(y)) * texel_size;
                let col = textureSample(screen_texture, texture_sampler, uv + offset).rgb;
                sum += col;
                sum_sq += col * col;
                count += 1.0;
            }
        }

        mean[k] = sum / count;
        let m2 = sum_sq / count;
        // Variance = E[X^2] - E[X]^2, summed across channels
        let v = m2 - mean[k] * mean[k];
        variance[k] = v.r + v.g + v.b;
    }

    // Pick sector with minimum variance
    var min_var = variance[0];
    var result = mean[0];
    for (var k = 1; k < 4; k++) {
        if (variance[k] < min_var) {
            min_var = variance[k];
            result = mean[k];
        }
    }

    return result;
}

// ─── Sobel Edge Detection ────────────────────────────────────
// Returns edge magnitude (0 = no edge, 1 = strong edge).

fn luminance(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn sobel_edge(uv: vec2<f32>, texel_size: vec2<f32>) -> f32 {
    // 3x3 kernel samples
    let tl = luminance(textureSample(screen_texture, texture_sampler, uv + vec2<f32>(-1.0, -1.0) * texel_size).rgb);
    let tc = luminance(textureSample(screen_texture, texture_sampler, uv + vec2<f32>( 0.0, -1.0) * texel_size).rgb);
    let tr = luminance(textureSample(screen_texture, texture_sampler, uv + vec2<f32>( 1.0, -1.0) * texel_size).rgb);
    let ml = luminance(textureSample(screen_texture, texture_sampler, uv + vec2<f32>(-1.0,  0.0) * texel_size).rgb);
    let mr = luminance(textureSample(screen_texture, texture_sampler, uv + vec2<f32>( 1.0,  0.0) * texel_size).rgb);
    let bl = luminance(textureSample(screen_texture, texture_sampler, uv + vec2<f32>(-1.0,  1.0) * texel_size).rgb);
    let bc = luminance(textureSample(screen_texture, texture_sampler, uv + vec2<f32>( 0.0,  1.0) * texel_size).rgb);
    let br = luminance(textureSample(screen_texture, texture_sampler, uv + vec2<f32>( 1.0,  1.0) * texel_size).rgb);

    // Sobel kernels
    let gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
    let gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;

    return sqrt(gx * gx + gy * gy);
}

// ─── Color Grading (Dark Fantasy Gothic) ─────────────────────
// Shifts palette toward amber shadows, muted midtones.

fn color_grade(col: vec3<f32>, saturation_mult: f32, warmth: f32) -> vec3<f32> {
    let lum = luminance(col);

    // Desaturate
    var graded = mix(vec3<f32>(lum), col, saturation_mult);

    // Warm shadows (add amber), cool highlights (add blue)
    let shadow_tint = vec3<f32>(0.15, 0.08, 0.02) * warmth;  // Amber
    let highlight_tint = vec3<f32>(-0.02, 0.0, 0.05) * warmth; // Cool blue

    let shadow_mask = 1.0 - smoothstep(0.0, 0.5, lum);
    let highlight_mask = smoothstep(0.5, 1.0, lum);

    graded += shadow_tint * shadow_mask;
    graded += highlight_tint * highlight_mask;

    // Slight contrast boost (S-curve)
    graded = graded * graded * (3.0 - 2.0 * graded);

    return clamp(graded, vec3<f32>(0.0), vec3<f32>(1.0));
}

// ─── Vignette + Film Grain ───────────────────────────────────

fn hash(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn vignette(uv: vec2<f32>, strength: f32) -> f32 {
    let d = distance(uv, vec2<f32>(0.5));
    return 1.0 - strength * smoothstep(0.3, 0.85, d);
}

fn grain(uv: vec2<f32>, time: f32, strength: f32) -> f32 {
    let noise = hash(uv * 500.0 + vec2<f32>(time * 100.0, time * 73.7));
    return (noise - 0.5) * strength;
}

// ─── Main Fragment Shader ────────────────────────────────────

@fragment
fn fragment(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let dims = vec2<f32>(textureDimensions(screen_texture));
    let texel_size = 1.0 / dims;

    let intensity = settings.intensity;

    // Early out if effect disabled
    if (intensity <= 0.01) {
        return textureSample(screen_texture, texture_sampler, uv);
    }

    // 1. Kuwahara oil painting filter
    let radius = i32(clamp(settings.kuwahara_radius, 1.0, 6.0));
    let painted = kuwahara(uv, texel_size, radius);

    // 2. Sobel edge detection — darken edges for hand-drawn look
    let edge = sobel_edge(uv, texel_size);
    let edge_darkened = painted * (1.0 - edge * settings.edge_strength);

    // 3. Color grading — dark fantasy palette
    let graded = color_grade(edge_darkened, settings.saturation, settings.warmth);

    // 4. Vignette + film grain
    let vig = vignette(uv, settings.vignette_strength);
    let g = grain(uv, settings.time, settings.grain_strength);
    let final_color = graded * vig + vec3<f32>(g);

    // Mix with original based on intensity
    let original = textureSample(screen_texture, texture_sampler, uv).rgb;
    let blended = mix(original, final_color, intensity);

    return vec4<f32>(clamp(blended, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
