// Build a PSD programmatically: AI-generated scene as background + smart object
// (screen) with perspective transform = detected green quad.
// Proves the "self-generated PSD" route for Dynamic Mockups.
const fs = require('fs');
const path = require('path');
const { PNG } = require('pngjs');
const { writePsdBuffer } = require('ag-psd');

const SCENE = process.argv[2];   // scene png (with green screen, used as-is for bg)
const SHOT = process.argv[3];    // screenshot png -> smart object content
const OUT = process.argv[4];     // out psd
// quad TL,TR,BR,BL as 8 numbers
const Q = process.argv[5].split(',').map(Number);

const scene = PNG.sync.read(fs.readFileSync(SCENE));
const shotBytes = fs.readFileSync(SHOT);
const shot = PNG.sync.read(shotBytes);

const W = scene.width, H = scene.height;
const xs = [Q[0], Q[2], Q[4], Q[6]], ys = [Q[1], Q[3], Q[5], Q[7]];
const bx0 = Math.max(0, Math.floor(Math.min(...xs))), by0 = Math.max(0, Math.floor(Math.min(...ys)));
const bx1 = Math.min(W, Math.ceil(Math.max(...xs))), by1 = Math.min(H, Math.ceil(Math.max(...ys)));
const bw = bx1 - bx0, bh = by1 - by0;

// preview raster for the placed layer: screenshot naive-resized into quad bbox
// (Dynamic Mockups re-renders from smart object + transform; preview is cosmetic)
const prev = new Uint8ClampedArray(bw * bh * 4);
for (let y = 0; y < bh; y++) {
  const sy = Math.min(shot.height - 1, Math.floor(y * shot.height / bh));
  for (let x = 0; x < bw; x++) {
    const sx = Math.min(shot.width - 1, Math.floor(x * shot.width / bw));
    const si = (sy * shot.width + sx) * 4, di = (y * bw + x) * 4;
    prev[di] = shot.data[si]; prev[di+1] = shot.data[si+1];
    prev[di+2] = shot.data[si+2]; prev[di+3] = 255;
  }
}

const sceneData = new Uint8ClampedArray(scene.data.buffer, scene.data.byteOffset, scene.data.length);

const psd = {
  width: W,
  height: H,
  linkedFiles: [{
    id: '20953ddb-9391-11ec-b4f1-c15674f50bc5',
    name: 'screen.png',
    type: 'png ',
    data: new Uint8Array(shotBytes),
  }],
  children: [
    {
      name: 'Background',
      left: 0, top: 0, right: W, bottom: H,
      imageData: { width: W, height: H, data: sceneData },
    },
    {
      name: 'Screen',
      left: bx0, top: by0, right: bx1, bottom: by1,
      imageData: { width: bw, height: bh, data: prev },
      placedLayer: {
        id: '20953ddb-9391-11ec-b4f1-c15674f50bc5',
        type: 'raster',
        // 4 corners TL TR BR BL in document coords; perspective lives in nonAffine
        transform: Q,
        nonAffineTransform: Q,
        width: shot.width,
        height: shot.height,
      },
    },
  ],
  // flattened composite (some parsers want it): use scene as-is
  imageData: { width: W, height: H, data: sceneData },
};

const buf = writePsdBuffer(psd, { generateThumbnail: false });
fs.writeFileSync(OUT, buf);
console.log('written', OUT, (buf.length / 1e6).toFixed(1) + 'MB',
  'quad-bbox', bx0, by0, bw, bh, 'shot', shot.width + 'x' + shot.height);
