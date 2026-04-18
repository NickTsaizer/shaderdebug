# shaderdebug

A Neovim plugin for live Slang shader debugging — preview what any line of your fragment shader outputs, right in the editor.

![shaderdebug preview](./assets/preview.mp4)

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
  "NickTsaizer/shaderdebug",
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

### Interactive Preview

The preview split shows:

1. **Header** — `<entry> > <expression>`
2. **API** — backend being used (e.g. `vulkan`)
3. **Inputs** — each reflected resource with current binding

Move the cursor onto an input line and press:

- **Enter** — edit that input (prompt for image path, JSON data, etc.)
- **x** — clear the input override
- **r** — refresh the preview

## Configuration

Pass options to `setup()`:

```lua
require("shaderdebug").setup({
  auto_preview = false,      -- start with auto-preview disabled
  debounce_ms = 180,        -- delay before rendering
  image_size = 512,         -- preview image resolution
  slangc = "slangc",        -- path to slangc
  glslang_validator = "glslangValidator",
})
```

## Known Limitations

- Only **fragment shaders** are supported
- Works best with **simple expressions** (assignments, returns)

## Credits

Built with [Slang](https://github.com/shader-slang/slang), [Vulkan](https://www.vulkan.org/), and [image.nvim](https://github.com/3rd/image.nvim).
