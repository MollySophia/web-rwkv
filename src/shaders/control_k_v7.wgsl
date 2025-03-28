struct View {
    shape: vec4<u32>,
    stride: vec4<u32>,
    offset: vec4<u32>,
};

@group(0) @binding(0) var<uniform> shape: vec4<u32>;                    // [C, T, B]
@group(0) @binding(1) var<uniform> va: View;                            // [C, T, B]
@group(0) @binding(2) var<uniform> vk: View;                            // [C, T, B]

@group(0) @binding(3) var<storage, read> p: array<vec2<u32>>;           // (1, 1, C)
#ifdef A_FP16
@group(0) @binding(4) var<storage, read> a: array<vec2<u32>>;           // (B, T, C)
#else
@group(0) @binding(4) var<storage, read> a: array<vec4<f32>>;           // (B, T, C)
#endif
#ifdef K_FP16
@group(0) @binding(5) var<storage, read_write> k: array<vec2<u32>>;     // (B, T, C)
#else
@group(0) @binding(5) var<storage, read_write> k: array<vec4<f32>>;     // (B, T, C)
#endif

fn pack4x16float(x: vec4<f32>) -> vec2<u32> {
    return vec2<u32>(pack2x16float(x.xy), pack2x16float(x.zw));
}

fn unpack4x16float(x: vec2<u32>) -> vec4<f32> {
    return vec4<f32>(unpack2x16float(x.x), unpack2x16float(x.y));
}

fn compute_index(view: View, batch: u32, token: u32, index: u32) -> u32 {
    let stride = view.stride.x >> 2u;
    let offset = vec3<u32>(view.offset.zy, view.offset.x >> 2u);
    return dot(vec3<u32>(batch, token, index) + offset, vec3<u32>(view.stride.y * stride, stride, 1u));
}

fn load_a(index: u32) -> vec4<f32> {
#ifdef A_FP16
    return unpack4x16float(a[index]);
#else
    return a[index];
#endif
}

fn load_k(index: u32) -> vec4<f32> {
#ifdef K_FP16
    return unpack4x16float(k[index]);
#else
    return k[index];
#endif
}

fn store_k(index: u32, value: vec4<f32>) {
#ifdef K_FP16
    k[index] = pack4x16float(value);
#else
    k[index] = value;
#endif
}

@compute @workgroup_size(BLOCK_SIZE, 1, 1)
fn main(@builtin(global_invocation_id) invocation_id: vec3<u32>) {
    let stride = shape.x / 4u;
    let index = invocation_id.x;
    let token = invocation_id.y;
    let batch = invocation_id.z;

    if index < stride {
        let _p = unpack4x16float(p[index]);
        let _a = load_a(compute_index(va, batch, token, index));
        let _k = load_k(compute_index(vk, batch, token, index));

        let value = _k * (vec4<f32>(1.0) + (_a - vec4<f32>(1.0)) * _p);
        store_k(compute_index(vk, batch, token, index), value);
    }
}