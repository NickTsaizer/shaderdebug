# shaderdebug

A Neovim plugin for live Slang shader debugging — preview what any line of your fragment shader outputs, right in the editor.

![shaderdebug preview](./assets/preview.gif)

## What it does

- **Live shader previews** — move your cursor to any Slang line and see what it outputs rendered on a quad
- **Reflection-driven** — automatically detects textures, buffers, samplers, and uniform bindings from your shader
- **Interactive inputs** — click or press Enter on any input to bind custom images, textures, or JSON data
- **Vulkan-backed** — renders previews using your system's Vulkan GPU for speed
- **Non-blocking** — everything runs in the background, so your editor never stutters

## Installation

### Using lazy.nvim

```lua
{
  "your-username/shaderdebug",
  ft = { "slang" },
  dependencies = { "3rd/image.nvim" },
}
```

Or with AstroNvim:

```lua
-- in lua/plugins/
{
  "your-username/shaderdebug",
  ft = { "slang" },
  dependencies = { "3rd/image.nvim" },
}
```

### Requirements

- **Neovim** 0.10+
- **image.nvim** — for displaying rendered previews inline
- **slangc** — Slang compiler (`~/VulkanSDK/.../bin/slangc`)
- **glslangValidator** — for SPIR-V compilation
- **Vulkan** — GPU rendering (works with Mesa/AMDVLK/Proprietary)
- **ffmpeg** — for non-PNG image conversion
- **libpng** — PNG reading/writing

## Quick Start

```vim
" Open a Slang shader file
:e myshader.slang

" Preview the current line
:ShaderDebugPreview

" Enable auto-preview on cursor move
:ShaderDebugToggleAuto
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:ShaderDebugPreview` | Render preview for the current line |
| `:ShaderDebugToggleAuto` | Toggle live preview on cursor move |
| `:ShaderDebugInputs` | Show reflected inputs in the message area |
| `:ShaderDebugSetImage <name> <path>` | Bind a single image to an input |
| `:ShaderDebugSetImages <name> <paths>` | Bind multiple images (comma-separated) |
| `:ShaderDebugSetData <name> <json>` | Bind JSON data to a buffer input |
| `:ShaderDebugClearInput <name>` | Clear an input override |
| `:ShaderDebugClear` | Close the preview and disable auto-preview |
| `:ShaderDebugOpenTestShader` | Open a test shader for experimentation |

### Interactive Preview

The preview split shows:

1. **Header** — `<entry> > <expression>`
2. **API** — backend being used (e.g. `vulkan`)
3. **Inputs** — each reflected resource with current binding

Move the cursor onto an input line and press:

- **Enter** — edit that input (prompt for image path, JSON data, etc.)
- **x** — clear the input override
- **r** — refresh the preview

### Example Workflow

```vim
" Open your shader
:e materials/my_shader.slang

" Enable live preview
:ShaderDebugToggleAuto

" Move cursor to a line like:
"   float4 color = sceneTexture.Sample(uv);

" The preview updates automatically!

" Want to use your own texture?
" Move to the 'sceneTexture' input row, press Enter
" Choose "Set image path", enter: ~/textures/my_texture.png

" Want to tweak a uniform buffer?
" Move to the 'globals' input row, press Enter
" Edit the JSON in the split, :write to apply
```

## Configuration

Pass options to `setup()`:

```lua
require("shaderdebug").setup({
  auto_preview = false,      -- start with auto-preview disabled
  debounce_ms = 180,        -- delay before rendering
  image_size = 512,         -- preview image resolution
  slangc = "slangc",        -- path to slangc
  glslang_validator = "glslangValidator",
  ffmpeg = "ffmpeg",
})
```

## How it works

1. **Instrument** — the current line is rewritten to `return __shaderdebug_toColor(<expr>);`
2. **Reflect** — Slang reflection extracts all shader inputs (textures, buffers, samplers)
3. **Compile** — both fragment (Slang→SPIR-V) and vertex (GLSL→SPIR-V) are compiled
4. **Bind** — inputs are bound with defaults or your custom overrides
5. **Render** — Vulkan draws a fullscreen quad with the instrumented shader
6. **Display** — PNG output is shown inline via image.nvim / kitty graphics

## Known Limitations

- Only **fragment shaders** are supported
- Works best with **simple expressions** (assignments, returns)
- Complex control flow may not render correctly in preview
- Requires GPU with **Vulkan 1.2+** support

## Credits

Built with [Slang](https://github.com/shader-slang/slang), [Vulkan](https://www.vulkan.org/), and [image.nvim](https://github.com/3rd/image.nvim).
