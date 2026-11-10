struct VertexInput {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
};

struct VertexOutput {
    @builtin(position) clipPosition: vec4f,
    @location(0) fragPos: vec3f,
    @location(1) normal: vec3f,
};

struct TransformUniforms {
    modelMatrix: mat4x4f,
    viewProjectionMatrix: mat4x4f,
    normalMatrix: mat3x3f, // Transpose of inverse model matrix to handle non-uniform scaling
};

struct MaterialUniforms {
    albedo: vec3f,
    roughness: f32,
    metallic: f32,
    ao: f32,
};

struct LightUniforms {
    lightDirection: vec3f,
    lightColor: vec3f,    
    ambientColor: vec3f,  
    viewPos: vec3f,       
};

// Bind Group Layout
@group(0) @binding(0) var<uniform> transforms: TransformUniforms;
@group(0) @binding(1) var<uniform> material: MaterialUniforms;
@group(0) @binding(2) var<uniform> sceneLighting: LightUniforms;

const PI: f32 = 3.14159265359;

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;

    // Transform vertex position to world space for lighting calculations
    let worldPos = transforms.modelMatrix * vec4f(input.position, 1.0);
    output.fragPos = worldPos.xyz;

    // Transform normal vector using the normal matrix to prevent scaling distortions
    output.normal = transforms.normalMatrix * input.normal;

    // Final position output to the rasterizer
    output.clipPosition = transforms.viewProjectionMatrix * worldPos;

    return output;
}

fn distributionGGX(N: vec3f, H: vec3f, roughness: f32) -> f32 {
    let a = roughness * roughness;
    let a2 = a * a;
    let NdotH = max(dot(N, H), 0.0);
    let NdotH2 = NdotH * NdotH;

    let num = a2;
    var denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;

    return num / max(denom, 0.0000001);
}

fn geometrySchlickGGX(NdotV: f32, roughness: f32) -> f32 {
    let r = (roughness + 1.0);
    let k = (r * r) / 8.0;

    let num = NdotV;
    let denom = NdotV * (1.0 - k) + k;

    return num / denom;
}

fn geometrySmith(N: vec3f, V: vec3f, L: vec3f, roughness: f32) -> f32 {
    let NdotV = max(dot(N, V), 0.0);
    let NdotL = max(dot(N, L), 0.0);
    let ggx2 = geometrySchlickGGX(NdotV, roughness);
    let ggx1 = geometrySchlickGGX(NdotL, roughness);

    return ggx1 * ggx2;
}

fn fresnelSchlick(cosTheta: f32, F0: vec3f) -> vec3f {
    return F0 + (vec3f(1.0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
    let N = normalize(input.normal);
    let V = normalize(sceneLighting.viewPos - input.fragPos);

    var F0 = vec3f(0.04);
    F0 = mix(F0, material.albedo, material.metallic);

    // Local surface reflectance (Directional light)
    let L = normalize(sceneLighting.lightDirection);
    let H = normalize(V + L);

    let D = distributionGGX(N, H, material.roughness);
    let G = geometrySmith(N, V, L, material.roughness);
    let F = fresnelSchlick(max(dot(H, V), 0.0), F0);

    let kS = F;
    var kD = vec3f(1.0) - kS;
    kD *= (1.0 - material.metallic);

    let numerator = D * G * F;
    let denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0);
    let specular = numerator / max(denominator, 0.0001);

    let diffuse = (kD * material.albedo) / PI;
    let NdotL = max(dot(N, L), 0.0);
    let directLighting = (diffuse + specular) * sceneLighting.lightColor * NdotL;

    // Constant isotropic ambient lighting
    let kA_S = F0; 
    var kA_D = vec3f(1.0) - kA_S;
    kA_D *= (1.0 - material.metallic);
    
    let ambientDiffuse = kA_D * material.albedo * sceneLighting.ambientColor;
    let ambient = ambientDiffuse * material.ao;

    // Output adjustments
    var color = ambient + directLighting;
    color = color / (color + vec3f(1.0)); // Tonemapping
    color = pow(color, vec3f(1.0 / 2.2)); // Gamma correction

    return vec4f(color, 1.0);
}