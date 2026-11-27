# tileit

Turn a texture, or a whole material (albedo, normal, roughness, height…),
into a seamlessly tiling in a few clicks.

Drop a photo (128 px to 4K and up) into the window, press **Tile it**, and
see the result tiled next to the original. Regular textures (bricks, tiles,
planks) are detected, straightened and fitted to whole repeats automatically.
Written in [Odin](https://odin-lang.org): a single executable with no runtime dependencies, so you can download it and just use it. 

**New to it?** Read the [user guide](docs/GUIDE.md): a first tile in a minute,
what the controls mean, recipes for bricks, sand, wood and material sets, and
fixes for common problems.

## Building

Needs an Odin compiler (any recent nightly). raylib and stb ship with Odin.

```
odin build . -o:speed
```

## Using it

**GUI**: run `tileit.exe`, or `tileit.exe some_texture.png` (this also makes
"Open with…" in Explorer work). Drop files into the window or use **Open…**.

Open **one map** and its siblings in the same folder are found by name
(`Bricks_Color` / `_NormalGL` / `_Roughness` / `_Displacement` / `_AmbientOcclusion`,
`brick_wall_diff_2k` / `_nor_gl_2k` / `_rough_2k` / `_arm_2k`, `wood-basecolor` /
`-normal`…), or pick several files at once. All maps get exactly the same edit.

| Control                               | What it does                                                                                                                      |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Tile it / Space                       | Run (in the background; the window stays responsive)                                                                              |
| Open…                                 | Native file dialog; pick one map or several                                                                                       |
| Save (all) / Ctrl+S                   | Write `<name>_tiled.png` next to each original                                                                                    |
| Save as…                              | Choose where; the other maps of the set go into the same folder                                                                   |
| Quick / Synth                         | How seams without a known repeat are handled (see below)                                                                          |
| Band, Seed, New seed                  | Synth: width of the rebuilt band; the seed (type your own, Enter to apply); next seed                                             |
| Preview, Swap sides, Tile input too   | View options                                                                                                                      |
| Output: Fitted / Input / 1K / 2K / 4K | Size of the saved tile; Input (default) gives back the size you started with. The resize wraps around, so the tile stays seamless |
| Albedo / Normal / … (Tab, 1–9)        | Which map of the set both panes show                                                                                              |
| Drag on the input                     | Select the part of the photo to use; drag inside to move it; Shift = square; right-click or Esc clears                            |
| Crop: Full / 1K / 2K / 4K             | Make a centred square selection of that size (then move it), or clear it                                                          |
| Fit to repeat + Crop / Stretch        | For regular textures: trim the tile to whole repeats, or rescale slightly (≤ 15%) to keep the whole selection                     |
| Straighten                            | Rotate out a slight tilt (0.3–15°)                                                                                                |
| Trusted centre                        | Central part of the photo that is measured and copied from (default 65%)                                                          |
| Flatten                               | Remove broad lighting gradients (colour map only)                                                                                 |
| Even contrast                         | Even out washed-out / extra-contrasty patches (colour map only)                                                                   |
| Scale                                 | Size of the area Flatten and Even contrast look at                                                                                |

On the input pane, the bright amber frame is your selection, the thin amber outline is its
trusted centre, and the white frame is the part the result was made from.
Changing a setting re-runs automatically when you let go of it.

**CLI**:

```
tileit IN OUT [options]          one texture (its name decides normal/colour/data handling)
tileit --set FILE [options]      a whole material set; writes <name>_tiled.png per map
  --mode quick|synth   --band B   --seed N
  --flatten F   --even E   --scale S
  --crop N                       centre-crop to at most N x N first
  --region X,Y,W,H               use only this rectangle of the input
  --repeat crop|stretch|off      fit regular textures to whole repeats (default crop)
  --straighten on|off            rotate out a slight tilt (default on)
  --size input|fitted|1024|2048|4096   output size (default input)
  --center F                     trusted central fraction (default 0.65)
  --preview PATH                 also write a 3x3 tiled preview
tileit --selftest                # FFT, map-name detection, 16-bit PNG round trip
tileit --compare A B             # mean/max pixel difference
tileit --make-test OUT [W H [16]]
```

It prints what it did (for example `straightened 4.1°, repeat 764x821,
quilted, cropped 1900x1900 -> 1529x1642`) and a **seam score**: the colour
jump across the wrap-around edges divided by the typical jump between
neighbouring pixels. A raw photo is usually 2–20; around 1 or below means the
seam is invisible.

## How it works

The papers behind each step are listed under [References](#references).

1. **Straighten** (`repeat.odin`). Gate: does a dominant edge direction exist
   (histogram of gradient directions folded modulo 90°)? Sand and grass fail
   it. If yes, the tilt is the angle at which the projected edge maps are
   sharpest (lines stack up), searched coarse-to-fine to 0.05°. The photo is
   rotated back and cropped to the largest rectangle inside it. Normal maps get
   their vectors rotated too.

2. **Selection**: the dragged region, or a centred size cap.

3. **Repeat detection** (`repeat.odin`), on the trusted centre only (photo
   edges carry lens distortion, perspective and vignetting). This is the
   autocorrelation via FFT of two blurred edge maps: mortar lines and joints.
   Brightness alone can't tell one course from two. The shortest strong peak
   is promoted to a multiple when that correlates clearly better, which catches
   half-brick offsets and alternating courses. The sample wall repeats every 2
   bricks × 4 courses. A small selection also uses the whole photo's measurement.

4. **Fit**: crop the tile (centred in the selection) to whole repeats, or
   **stretch** the photo slightly so the selection holds whole repeats exactly.

5. **Quilting** (`quilt.odin`) for axes with a repeat. The photo shows what
   comes after the tile's edge: the pixels one tile-width further along the
   same wall. Near each edge, a dynamic-programming minimum-error cut (Efros &
   Freeman 2001) chooses per row (and per column) where to switch from the tile
   to that real continuation. Every pixel comes from exactly one place in the
   photo, so joints can't double ("ghosts") or merge. A screened Poisson pass
   (Pérez et al. 2003; Bhat et al. 2008) evens out the tone along the cuts. The
   bottom cut uses rows that already have the left/right cut applied, so the
   corner is consistent. If the photo has no room past the tile, it falls back
   to step 7.

6. **Quick** (`tile.odin`): *periodic-plus-smooth decomposition* (Moisan 2011)
   removes what's left of the edge mismatch. Colour maps work on log-luminance
   (lighting becomes additive, so **Flatten** removes it and **Even contrast**
   equalises local contrast, a simple form of Moritz et al. 2017's
   stationarisation) plus colour as a ratio to luminance (bounded, so nothing
   gets tinted). Data maps are handled linearly per channel.

7. **Synth** (`synth.odin`), for seams without a repeat (or without room to
   quilt). Shift by half, rebuild a band around the seam coarse-to-fine with
   PatchMatch (Barnes et al. 2009) in an EM loop (Wexler et al. 2007). Copies
   come only from the trusted centre, and when a repeat is known, only from
   whole repeats away. A reuse penalty spreads copies over more of the photo
   (completeness). The final level copies each pixel from its best match and
   records a source map; screened Poisson blends it; the image is shifted back.

**Material sets** (`material.odin`): the colour map drives every decision.
Every other map gets the same straightening, crop, quilt cuts, Synth source
map and blends. Normal maps are re-normalised. On a test set, the tiled normal
map agrees with normals derived from the tiled height map to within ~0.8°.

**Output**: PNG with the source's channel count and bit depth. 16-bit inputs
(height maps) stay 16-bit, via a small built-in PNG/DEFLATE writer
(`png16.odin`), because stb only writes 8-bit.

Everything is multithreaded and **deterministic**: same input, settings and
seed give byte-identical output on any machine.

## Files

| File | Contents |
|---|---|
| `main.odin` | CLI, GUI (raylib/raygui), background job, selection |
| `theme.odin` | Amber-on-black theme, system font, toolbar auto-layout |
| `dialogs.odin` | Native Open / Save As dialogs (Windows) |
| `material.odin` | Map kinds, sibling detection, the whole pipeline (`tile_material`) |
| `repeat.odin` | Crop, resample, repeat detection, tilt detection, straightening |
| `quilt.odin` | Minimum-error-cut quilting from the photo's continuation |
| `tile.odin` | Image I/O, Quick mode (P+S, flatten, even contrast), seam score |
| `synth.odin` | Synth mode: pyramid, PatchMatch, voting, reuse penalty, blend setup |
| `poisson.odin` | Masked screened-Laplacian CG solver |
| `png16.odin` | 16-bit PNG writer with its own DEFLATE compressor |
| `winimage.odin` | JPEG (and other) decoding via Windows GDI+, where stb can't read them |
| `fft.odin` | Radix-2 + Bluestein FFT (any size), 2D threaded |
| `parallel.odin` | Deterministic `parallel_for` |

Debug: `-define:TILEIT_TRACE=true` logs solver iterations, repeat candidates
and tilt measurement. Hidden commands: `--autotest FILE OUT.png` (drives the GUI
and saves screenshots), `--make-test-set ALBEDO DIR NAME`, `--check-normals H N`,
`--rotate IN OUT DEG`, `--bluish IMG`.

## Known limitations

- Repeat detection handles axis-aligned lattices (after straightening);
  strongly perspective-distorted walls (converging lines) aren't rectified.
- Synth on stochastic textures (sand) can still produce a slightly softer patch
  now and then. **New seed** or Quick help.
- No EXR / HDR output (PNG 8/16-bit only).
- JPEGs are decoded by Windows (GDI+): raylib links its own copy of stb_image
  without JPEG support, which shadows stb's. Elsewhere, convert JPEGs to PNG
  first.
- The selection overlay is drawn axis-aligned on the original photo even when
  the photo was straightened.
- Dialogs are Windows-only (drag and drop works everywhere raylib does).

## License

tileit is released under the [MIT License](LICENSE): use it, change it, ship it,
sell things you made with it, in free or commercial projects. Textures you make
with tileit are yours; the licence covers the tool, not its output.

The executable includes code from Odin, raylib, raygui and stb, all under
permissive licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## References

tileit is built from published methods. Where to look if you want the details,
grouped by the step that uses them (see [How it works](#how-it-works)):

**Making edges match (Quick)**
- L. Moisan. *Periodic plus Smooth Image Decomposition.* Journal of
  Mathematical Imaging and Vision 39(2), 161–179, 2011.
  [doi:10.1007/s10851-010-0227-1](https://doi.org/10.1007/s10851-010-0227-1)

**Joining regular textures from the photo's continuation (quilting)**
- A. A. Efros, W. T. Freeman. *Image Quilting for Texture Synthesis and
  Transfer.* Proc. SIGGRAPH 2001, 341–346.
  [doi:10.1145/383259.383296](https://doi.org/10.1145/383259.383296)
  (the minimum-error boundary cut)

**Rebuilding seams (Synth)**
- C. Barnes, E. Shechtman, A. Finkelstein, D. B. Goldman. *PatchMatch: A
  Randomized Correspondence Algorithm for Structural Image Editing.* ACM
  Transactions on Graphics 28(3), 2009 (Proc. SIGGRAPH).
  [doi:10.1145/1531326.1531330](https://doi.org/10.1145/1531326.1531330)
- Y. Wexler, E. Shechtman, M. Irani. *Space-Time Completion of Video.* IEEE
  Transactions on Pattern Analysis and Machine Intelligence 29(3), 463–476, 2007.
  [doi:10.1109/TPAMI.2007.60](https://doi.org/10.1109/TPAMI.2007.60)
  (the coarse-to-fine EM loop and patch voting)
- L.-Y. Wei, M. Levoy. *Fast Texture Synthesis using Tree-structured Vector
  Quantization.* Proc. SIGGRAPH 2000, 479–488.
  [doi:10.1145/344779.345009](https://doi.org/10.1145/344779.345009)
  (synthesis with wrap-around neighbourhoods, which yields tileable results)
- A. Kaspar, B. Neubert, D. Lischinski, M. Pauly, J. Kopf. *Self Tuning
  Texture Optimization.* Computer Graphics Forum 34(2), 349–359, 2015 (Proc.
  Eurographics). [doi:10.1111/cgf.12565](https://doi.org/10.1111/cgf.12565)
  (spreading copies over the source; tileit's reuse penalty is a simple form)

**Blending (removing tone steps along cuts and rebuilt bands)**
- P. Pérez, M. Gangnet, A. Blake. *Poisson Image Editing.* ACM Transactions on
  Graphics 22(3), 313–318, 2003 (Proc. SIGGRAPH).
  [doi:10.1145/882262.882269](https://doi.org/10.1145/882262.882269)
- P. Bhat, B. Curless, M. Cohen, C. L. Zitnick. *Fourier Analysis of the 2D
  Screened Poisson Equation for Gradient Domain Problems.* Proc. ECCV 2008,
  114–128. [doi:10.1007/978-3-540-88688-4_9](https://doi.org/10.1007/978-3-540-88688-4_9)

**Repeat detection and stationarity**
- Y. Liu, W.-C. Lin, J. Hays. *Near-Regular Texture Analysis and
  Manipulation.* ACM Transactions on Graphics 23(3), 368–376, 2004 (Proc.
  SIGGRAPH). [dblp record](https://dblp.org/rec/journals/tog/LiuLH04)
  (finding a texture's lattice from its autocorrelation)
- J. Moritz, S. James, T. S. F. Haines, T. Ritschel, T. Weyrich. *Texture
  Stationarization: Turning Photos into Tileable Textures.* Computer Graphics
  Forum 36(2), 177–188, 2017 (Proc. Eurographics).
  [doi:10.1111/cgf.13117](https://doi.org/10.1111/cgf.13117)
  (why uneven photos repeat visibly; Even contrast is a simple form of its
  local histogram matching)

**Numerics**
- L. I. Bluestein. *A Linear Filtering Approach to the Computation of Discrete
  Fourier Transform.* IEEE Transactions on Audio and Electroacoustics 18(4),
  451–455, 1970. [doi:10.1109/TAU.1970.1162132](https://doi.org/10.1109/TAU.1970.1162132)
  (FFTs of any size, not only powers of two)
- M. R. Hestenes, E. Stiefel. *Methods of Conjugate Gradients for Solving
  Linear Systems.* Journal of Research of the National Bureau of Standards
  49(6), 409–436, 1952. (the Poisson solver)
- R. G. Keys. *Cubic Convolution Interpolation for Digital Image Processing.*
  IEEE Transactions on Acoustics, Speech, and Signal Processing 29(6),
  1153–1160, 1981. [doi:10.1109/TASSP.1981.1163711](https://doi.org/10.1109/TASSP.1981.1163711)
  (the bicubic kernel used for the wrap-around output resize)

**Further reading** (related work tileit doesn't use, mostly learned methods)
- V. Kwatra, A. Schödl, I. Essa, G. Turk, A. Bobick. *Graphcut Textures: Image
  and Video Synthesis Using Graph Cuts.* ACM Transactions on Graphics 22(3),
  277–286, 2003 (Proc. SIGGRAPH).
  [doi:10.1145/882262.882264](https://doi.org/10.1145/882262.882264)
- C. Rodriguez-Pardo, E. Garces. *SeamlessGAN: Self-Supervised Synthesis of
  Tileable Texture Maps.* IEEE Transactions on Visualization and Computer
  Graphics, 2022. [arXiv:2201.05120](https://arxiv.org/abs/2201.05120)
- C. Rodriguez-Pardo, D. Casas, E. Garces, J. Lopez-Moreno. *TexTile: A
  Differentiable Metric for Texture Tileability.* Proc. CVPR 2024.
  [arXiv:2403.12961](https://arxiv.org/abs/2403.12961)
- O. Madar, O. Fried. *Tiled Diffusion.* Proc. CVPR 2025.
  [arXiv:2412.15185](https://arxiv.org/abs/2412.15185)
