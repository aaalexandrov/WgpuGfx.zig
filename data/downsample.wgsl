@group(0) @binding(0) var srcTex: texture_2d<f32>;
@group(0) @binding(1) var dstTex: texture_storage_2d<rgba8unorm, write>;

fn compute_sample(s00: vec4f, s01: vec4f, s10: vec4f, s11: vec4f) -> vec4f {
    return (s00 + s01 + s10 + s11) * 0.25;
}

@compute @workgroup_size(8, 8)
fn cs_main(@builtin(global_invocation_id) id: vec3<u32>) {
    let srcCoord = 2u * id.xy;
    let s00 = textureLoad(srcTex, srcCoord + vec2u(0, 0), 0);
    let s01 = textureLoad(srcTex, srcCoord + vec2u(0, 1), 0);
    let s10 = textureLoad(srcTex, srcCoord + vec2u(1, 0), 0);
    let s11 = textureLoad(srcTex, srcCoord + vec2u(1, 1), 0);            
    let sample = compute_sample(s00, s01, s10, s11);
    textureStore(dstTex, id.xy, sample);
}