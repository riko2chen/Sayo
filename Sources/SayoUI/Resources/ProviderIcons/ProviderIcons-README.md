# Provider icons

Artwork from [LobeHub Icons](https://github.com/lobehub/lobe-icons),
`@lobehub/icons-static-svg` version **1.95.1**, commit
`49a2130df7bfa5eb1b088261bff20a37e2967789`.
See `LobeIcons-LICENSE.txt` for the upstream MIT license.

These SVGs are bundled for offline use. Native AppKit renders their vector
paths and original colors; no runtime download or third-party renderer is used.

For macOS CoreSVG compatibility, the upstream `1em` dimensions are replaced
with the viewBox dimensions, the web layout style is removed, and path commands
and arguments are separated by spaces (using svgpath 2.6.0). This avoids CoreSVG
misreading compressed arc flags. Geometry, gradients and colors are unchanged.

Gemini Nano uses the Gemini mark. Intern-AI uses InternLM, Moonshot uses Kimi,
and SiliconFlow uses the upstream `siliconcloud-color` mark. Kimi uses the
monochrome variant for contrast on the light settings background. Local models,
custom services and Magpie retain their existing system icons.
