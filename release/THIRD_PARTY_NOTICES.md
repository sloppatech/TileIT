# Third-party notices

tileit itself is MIT-licensed (see `LICENSE`). The tileit executable also
contains code from the following projects, which ship with the Odin compiler.
Their licences are reproduced here with thanks.

| Component | Used for | Licence |
|---|---|---|
| Odin core library, by Ginger Bill | Language runtime, FFT helpers, threads, file I/O | zlib |
| raylib, by Ramon Santamaria (@raysan5) | Window, input, drawing, textures | zlib |
| raygui, by Ramon Santamaria (@raysan5) | Buttons, sliders and other controls | zlib (same terms as raylib) |
| stb_image and stb_image_write, by Sean Barrett | Reading images, writing 8-bit PNG | Public domain or MIT, at your choice |

On Windows, tileit also uses system components (GDI+ for decoding JPEGs, the
common dialogs for Open and Save As) and loads an installed system font
(Cascadia Mono or Consolas). These are part of Windows and are not
redistributed with tileit.

The research papers tileit's methods come from are listed in the README under
"References".

---

## Odin

```
Copyright (c) 2016-2025 Ginger Bill. All rights reserved.

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

## raylib (and raygui, under the same terms)

```
Copyright (c) 2013-2026 Ramon Santamaria (@raysan5)

This software is provided "as-is", without any express or implied warranty. In no event
will the authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not claim that you
  wrote the original software. If you use this software in a product, an acknowledgment
  in the product documentation would be appreciated but is not required.

  2. Altered source versions must be plainly marked as such, and must not be misrepresented
  as being the original software.

  3. This notice may not be removed or altered from any source distribution.
```

## stb_image, stb_image_write

Used under the MIT alternative (the public-domain alternative also applies):

```
Copyright (c) 2017 Sean Barrett

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
