struct View {
    shape: vec4<u32>,
    stride: vec4<u32>,
    offset: vec4<u32>,
};

@group(0) @binding(0) var<uniform> vf: View;
@group(0) @binding(1) var<uniform> vx: View;
@group(0) @binding(2) var<uniform> vy: View;

#ifdef FACTOR_FP16
@group(0) @binding(3) var<storage, read> f: array<vec2<u32>>;           // (B?, T?, C)
#else
@group(0) @binding(3) var<storage, read> f: array<vec4<f32>>;           // (B?, T?, C)
#endif
#ifdef IN_FP16
@group(0) @binding(4) var<storage, read> x: array<vec2<u32>>;           // (B, T, C)
#else
@group(0) @binding(4) var<storage, read> x: array<vec4<f32>>;           // (B, T, C)
#endif
#ifdef OUT_FP16
@group(0) @binding(5) var<storage, read_write> y: array<vec2<u32>>;     // (B, T, C)
#else
@group(0) @binding(5) var<storage, read_write> y: array<vec4<f32>>;     // (B, T, C)
#endif

fn compute_index(view: View, batch: u32, token: u32, index: u32) -> u32 {
    let stride = view.stride.x >> 2u;
    let offset = vec3<u32>(view.offset.zy, view.offset.x >> 2u);
    return dot(vec3<u32>(batch, token, index) + offset, vec3<u32>(view.stride.y * stride, stride, 1u));
}

fn pack4x16float(x: vec4<f32>) -> vec2<u32> {
    return vec2<u32>(pack2x16float(x.xy), pack2x16float(x.zw));
}

fn unpack4x16float(x: vec2<u32>) -> vec4<f32> {
    return vec4<f32>(unpack2x16float(x.x), unpack2x16float(x.y));
}

fn load_f(index: u32) -> vec4<f32> {
#ifdef FACTOR_FP16
    return unpack4x16float(f[index]);
#else
    return f[index];
#endif
}

fn load_x(index: u32) -> vec4<f32> {
#ifdef IN_FP16
    return unpack4x16float(x[index]);
#else
    return x[index];
#endif
}

fn load_y(index: u32) -> vec4<f32> {
#ifdef OUT_FP16
    return unpack4x16float(y[index]);
#else
    return y[index];
#endif
}

fn store_y(index: u32, value: vec4<f32>) {
#ifdef OUT_FP16
    y[index] = pack4x16float(value);
#else
    y[index] = value;
#endif
}

@compute @workgroup_size(BLOCK_SIZE, 1, 1)
fn lerp(@builtin(global_invocation_id) invocation_id: vec3<u32>) {
    let stride = vf.shape.x / 4u;
    let index = invocation_id.x;
    let token = invocation_id.y;
    let batch = invocation_id.z;

    if all(vec3<u32>(index, token, batch) < vec3<u32>(stride, vf.shape.yz)) {
        let _f = load_f(compute_index(vf, select(batch, 0u, vf.shape.z == 1u), select(token, 0u, vf.shape.y == 1u), index));
        let _x = load_x(compute_index(vx, batch, token, index));
        let _y = load_y(compute_index(vy, batch, token, index));
        
#ifdef REVERSED
        let value = mix(_y, _x, _f);
#else
        let value = mix(_x, _y, _f);
#endif

        store_y(compute_index(vy, batch, token, index), value);
    }
}
