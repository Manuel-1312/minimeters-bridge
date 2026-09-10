# MiniMeters renderer for spicetify-visualizer

`MiniMetersVisualizer.tsx` is a renderer for **[Konsl's spicetify-visualizer](https://github.com/Konsl/spicetify-visualizer)**
(MIT). It draws the metrics streamed by the bridge in this repo in the style of the MiniMeters
*Analysis Master* preset: spectrogram, spectrum, waveform, oscilloscope, stereometer and loudness.

Credit for the visualizer framework — the custom-app shell, the build tooling and the other
renderers — goes to Konsl. This file only adds one renderer.

## Install

1. Clone Konsl's visualizer and install its dependencies:

       git clone https://github.com/Konsl/spicetify-visualizer
       cd spicetify-visualizer
       npm install

2. Copy `MiniMetersVisualizer.tsx` into `src/components/renderer/`.

3. Register it in `src/defs.ts`:

   - add the import at the top:

         import MiniMetersVisualizer from "./components/renderer/MiniMetersVisualizer";

   - add an entry to the `RENDERERS` object:

         minimeters: {
             name: "MiniMeters",
             requiredAudioData: ["extractedColor"],
             renderer: MiniMetersVisualizer
         }

4. Build and install the custom app:

       npm run build
       # copy dist/{index.js,manifest.json,style.css} into
       #   %APPDATA%\spicetify\CustomApps\visualizer\
       spicetify apply

5. Start the bridge (`python bridge.py` from the repo root) and open the visualizer in
   Spotify, then pick **MiniMeters**.

The renderer connects to `ws://127.0.0.1:8985`. If the bridge is not running it shows
*bridge sin conexión*.

## Note
This renderer expects the bridge's binary frame format (see the repo-root README). It does
**not** use Spotify's precomputed audio analysis — the numbers come from the real output signal.
