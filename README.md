# Web-RWKV
[![crates.io](https://img.shields.io/crates/v/web-rwkv)](https://crates.io/crates/web-rwkv)
[![docs.rs](https://docs.rs/web-rwkv/badge.svg)](https://docs.rs/web-rwkv)

<p align='center'><image src="assets/logo-zx2.png" height=256></p>
<p align='center'><image src="assets/logo-ba.png"></p>

This is an inference engine for the [language model of RWKV](https://github.com/BlinkDL/RWKV-LM) implemented in pure WebGPU.

## Features
- No dependencies on CUDA/Python.
- Support Nvidia/AMD/Intel GPUs, including integrated GPUs.
- Vulkan/Dx12/OpenGL backends.
- WASM support ([can run in browser](https://cryscan.github.io/web-rwkv-puzzles/)).
- Batched inference.
- Int8 and Float4 quantization.
- Very fast.
- LoRA merging at loading time.
- Support RWKV V4 through V7.
- Hooks to intervene the inference process at any point.
- Model (de)serialization.

<p align='center'>
<image src="screenshots/chat.gif">
<image src="screenshots/batch.gif">
</p>

Note that `web-rwkv` is only an inference engine. It only provides the following functionalities:
- A tokenizer.
- Model loading.
- State creation and updating.
- Model implements `run` function that takes in prompt tokens and returns logits, and a `softmax` function that turns logits into predicted next token probabilities. Both of them are executed on GPU.
- Model quantization and (de)serialization.
- WASM bindings.

It *does not* provide the following:
- OpenAI API or APIs of any kind.
  - If you would like to deploy an API server, check [AI00 RWKV Server](https://github.com/cgisky1980/ai00_rwkv_server) which is a fully-functional OpenAI-compatible API server built upon `web-rwkv`.
  - You could also check the [`web-rwkv-axum`](https://github.com/Prunoideae/web-rwkv-axum) project if you want some fancy inference pipelines, including Classifier-Free Guidance (CFG), Backus–Naur Form (BNF) guidance, and more.
- Samplers, though in the examples a basic nucleus sampler is implemented, this is *not* included in the library itself.
- State caching or management system.
- Python bindings.

> For devs: Check the [slides](./assets/introduction.pdf) for technique details about the architecture, history and optimizations. 

## Compile
1. [Install Rust](https://rustup.rs/).
2. Download the model from [HuggingFace](https://huggingface.co/BlinkDL/rwkv-5-world), and convert it using [`convert_safetensors.py`](./assets/scripts/convert_safetensors.py). Put the `.st` model under `assets/models`.
3. Compile
   ```bash
   $ cargo build --release --examples
   ```

## Examples

### Performance Test
The test generates 500 tokens and measure the time cost.
```bash
$ cargo run --release --example gen
```

### Chat Demo
To chat with the model, run
```bash
$ cargo run --release --example chat
```

In this demo, type `+` to retry last round's generation; type `-` to exit.

- To specify the location of your safetensors model, use 
   ```bash
   $ cargo run --release --example chat -- --model /path/to/model
   ```

- To load custom prompts for chat, use 
   ```bash
   $ cargo run --release --example chat -- --prompt /path/to/prompt
   ```
   See [`assets/prompt.json`](./assets/prompt.json) for details.

- To specify layer quantization, use `--quant <LAYERS>` or `--quant-nf4 <LAYERS>` to quantize the first `<LAYERS>` layers. For example, use 
  ```bash
  $ cargo run --release --example chat -- --quant 32
  ```
  to quantize all 32 layers.


### Batched Inference
This demo showcases generation of 4 batches of text with various lengths simultaneously.
```bash
$ cargo run --release --example batch
```

### Inspector
The inspector demo is a guide to an advanced usage called hooks. Hooks allow user to inject any tensor ops into the model's inference process, fetching and modifying the contents of the runtime buffer, state, and even the model parameters. Hooks enable certain third-party implementations like dynamic LoRA, control net, and so on.

### (De)serialization
All versions of models implements `serde::ser::Serialize` and `serde::de::DeserializeSeed<'de>`, which means that one can save quantized or lora-merged model into a file and load it afterwards.

## Use in Your Project
To use in your own rust project, simply add `web-rwkv = "0.10"` as a dependency in your `Cargo.toml`.
Check examples on how to create the environment, the tokenizer and how to run the model.

## Explanations

### Inference Runtime
Since v0.7 there is a `runtime` feature for the crate. When enabled, applications can use infrastructures of the asynchronous `runtime` API.

In general, a `runtime` is an asynchronous task that is driven by `tokio`. It allows CPU and GPU to work in parallel, maximizing the utilization of GPU computing resource.

Check examples starting with `rt` for more information, and compare the generation speed with their non-`rt` counterparts.

### Batched Inference
Since version v0.2.4, the engine supports batched inference, i.e., inference of a batch of prompts (with different length) in parallel.
This is achieved by a modified `WKV` kernel.

When building the model, the user specifies `token_chunk_size` (default: 32, but for powerful GPUs this could be much higher), which is the maximum number of tokens the engine could process in one `run` call.

After creating the model, the user creates a `ModelState` with `num_batch` specified.
This means that there are `num_batch` slots that could consume the inputs in parallel.

Before calling `run()`, the user fills each slot with some tokens as prompt.
If a slot is empty, no inference will be run for it.

After calling `run()`, some (but may not be all) input tokens are consumed, and `logits` appears in their corresponding returned slots if the inference of that slot is finished during this run.
Since there are only `token_chunk_size` tokens are processed during each `run()` call, there may be none of `logits` appearing in the results.

### Hooks
Hooks are a very powerful tool for customizing model inference process.
The library provides with the `Model::run_with_hooks` function, which takes into a `HookMap` as a parameter.

- A `HookMap` is essentially a hashmap from `Model::Hook` to functions.
- A `Model::Hook` defines a certain place the hook function can be injected into. A model generally has dozens of hooking points.
- A hook function is a function of `Fn(&Frame) -> Result<TensorOp, TensorError>`, where you can create tensor ops that reads/writes all the tensors you get here.
- A `Frame` contains all accessible GPU buffers during the inference, including the state and all runtime buffers.

An example reading out every layer's output during inference:
```rust
let info = model.info();

#[derive(Debug, Clone)]
struct Buffer(TensorGpu<f32, ReadWrite>);

// create a buffer to store each layer's output
let buffer = Buffer(context.tensor_init([info.num_emb, info.num_layer, 1, 1]));

let mut hooks = HookMap::default();
for layer in 0..info.num_layer {
   // cloning a buffer doesn't actually clone its internal data; use `deep_clone()` to clone to a new buffer
   let buffer = buffer.clone();
   hooks.insert(
      v6::Hook::PostFfn(layer),
      Box::new(
            move |frame: &v6::Frame<_>| -> Result<TensorOp, TensorError> {
               // figure out how many tokens this run has
               let shape = frame.buffer.ffn_x.shape();
               let num_token = shape[1];
               // "steal" the layer's output (activation), and put it into our buffer
               TensorOp::blit(
                  frame.buffer.ffn_x.view(.., num_token - 1, .., ..)?,
                  buffer.0.view(.., layer, .., ..)?,
               )
            },
      ),
   );
}

let bundle = v6::Bundle::<f16>::new_with_hooks(model, 1, hooks);
let runtime = TokioRuntime::new(bundle).await;

let (input, output) = runtime.infer(input).await?;
// now the data is available in `buffer`, we can read it back
let data = buffer.back().await.to_vec();
```

## Convert Models
*You must download the model and put in `assets/models` before running if you are building from source.*
You can now download the converted models [here](https://huggingface.co/cgisky/RWKV-safetensors-fp16).

You may download the official RWKV World series models from [HuggingFace](https://huggingface.co/BlinkDL/rwkv-5-world), and convert them via the provided [`convert_safetensors.py`](assets/scripts/convert_safetensors.py).

```bash
$ python assets/scripts/convert_safetensors.py --input /path/to/model.pth --output /path/to/model.st
```

If you don't have python installed or don't want to, there is a pure rust [`converter`](https://github.com/cryscan/web-rwkv-converter).
You can clone that repo and run
```bash
$ cd /path/to/web-rwkv-converter
$ cargo run --release --example converter -- --input /path/to/model.pth --output /path/to/model.st
```

## Troubleshoot
- "thread 'main' panicked at 'called `Result::unwrap()` on an `Err` value: HeaderTooLarge'"
  
  Your model is broken, mainly because you cloned the repo but did not set up git-lfs.Please download the model manually and overwrite that one in `assets/models`.

- "thread 'main' panicked at 'Error in Queue::submit: parent device is lost'"

  Your GPU is not responding.
  Maybe you are running a model that is just too big for your device. If the model doesn't fit into your VRam, the driver needs to constantly swap and transfer the model parameters, causing it to be 10x slower.
  Try to quantize your model first.

##  Debugging Rust on Windows
Source: [link](https://github.com/rust-lang/rust-analyzer/issues/18535).

The default toolchain installed on Windows by `Rustup` is the `x86_64-pc-windows-msvc` toolchain. This toolchain does not include Rust-specific formatters for LLDB, as it is assumed that users will primarily use WinDbg or Microsoft Visual Studio's debugger for this target.
If you prefer to use `CodeLLDB` for debugging, you have two options:

1. Use the `x86_64-pc-windows-gnu` toolchain to compile your Rust project: This option ensures full LLDB visualization support for Rust types.
2. Compile with the `x86_64-pc-windows-msvc` toolchain but use LLDB formatters from `x86_64-pc-windows-gnu`: To use this option, install the `x86_64-pc-windows-gnu` toolchain via `rustup toolchain add x86_64-pc-windows-gnu`.
Then, configure CodeLLDB to load its formatters by adding the following entry to your workspace configuration:

```json
"lldb.script": { "lang.rust.toolchain": "x86_64-pc-windows-gnu" }
```

Note that this setup is less ideal due to differences in the debug information layout emitted by the Rust compiler for enum data types when targeting MSVC, which means enums may not be visualized correctly. However, LLDB formatters will work for standard collections like strings and vectors.

## Credits
- Tokenizer is implemented by [@koute](https://github.com/koute/rwkv_tokenizer).
- The [Logo](assets/logo-zx2-transparent.png) is inspired from the Re;ON Type-ZX7 logo by Riez-ON. It is generated by Flux Dev and processed manually. The original ZX7 logo is licensed to be used in non-commercial projects.
