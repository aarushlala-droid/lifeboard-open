import { cpSync, copyFileSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { build } from "esbuild";

const root = new URL("../", import.meta.url);
const publicDir = new URL("../public/", import.meta.url);
rmSync(publicDir, { recursive: true, force: true });
mkdirSync(publicDir, { recursive: true });
for (const name of readdirSync(new URL("../web/", import.meta.url))) {
  if (name === "ocr.js") continue;
  copyFileSync(new URL(`../web/${name}`, import.meta.url), new URL(`../public/${name}`, import.meta.url));
}
await build({ entryPoints: [new URL("../web/ocr.js", import.meta.url).pathname], outfile: new URL("../public/ocr.js", import.meta.url).pathname,
  bundle: true, minify: true, platform: "browser", format: "esm", target: ["safari16.4"] });
const workerDir = new URL("../public/ocr/", import.meta.url);
const coreDir = new URL("../public/ocr/core/", import.meta.url);
const langDir = new URL("../public/ocr/lang/", import.meta.url);
mkdirSync(workerDir, { recursive: true }); mkdirSync(coreDir, { recursive: true }); mkdirSync(langDir, { recursive: true });
copyFileSync(new URL("../node_modules/tesseract.js/dist/worker.min.js", import.meta.url), new URL("../public/ocr/worker.min.js", import.meta.url));
for (const variant of ["", "simd-", "relaxedsimd-"]) {
  for (const suffix of [".js", ".wasm.js", ".wasm"]) {
    const name = `tesseract-core-${variant}lstm${suffix}`;
    copyFileSync(new URL(`../node_modules/tesseract.js-core/${name}`, import.meta.url), new URL(`../public/ocr/core/${name}`, import.meta.url));
  }
}
copyFileSync(new URL("../node_modules/@tesseract.js-data/eng/4.0.0_best_int/eng.traineddata.gz", import.meta.url), new URL("../public/ocr/lang/eng.traineddata.gz", import.meta.url));
console.log("LifeBoard mobile PWA built");
