# CUI

GPU-rendered retained-mode UI library for C3. Widgets form a retained element
tree with cached layout and paint; every drawing is an SDF primitive rendered
in a single instanced draw call. Transform animations write one matrix into a
GPU palette and re-run neither layout nor paint.

### Running the example

Install C3 from https://c3-lang.org/

Install the Vulkan SDK (the example links against `libvulkan` in
`/usr/local/lib`; on macOS a Vulkan-on-Metal driver such as KosmicKrisp or
MoltenVK is required).

Shaders are written in [Slang](https://shader-slang.org/). Rebuild the SPIR-V
after editing `src/shaders/shader.slang`:

```
c3c build shaders
```

(a prebuilt `shader.spv` is checked in, so this is only needed when the shader
changes).

Then run the example with:

```
c3c run ui
```

Drag with the left mouse button to rotate the cards. Escape quits.
