import { createWorker } from "tesseract.js";
import { assessOCR } from "./ocr-quality.js";

let workerPromise;
export function prepareOCR() {
  workerPromise ??= createWorker("eng", 1, {
    workerPath: "/ocr/worker.min.js",
    corePath: "/ocr/core",
    langPath: "/ocr/lang/",
    workerBlobURL: false,
  });
  return workerPromise;
}

async function decodeImage(file) {
  if (typeof createImageBitmap === "function") {
    try { return await createImageBitmap(file, { imageOrientation: "from-image" }); }
    catch {
      try { return await createImageBitmap(file); }
      catch { /* Fall back to the image element below. */ }
    }
  }
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const image = new Image();
    image.onload = () => { URL.revokeObjectURL(url); resolve(image); };
    image.onerror = () => { URL.revokeObjectURL(url); reject(new Error("This photo could not be opened")); };
    image.src = url;
  });
}

async function resize(file) {
  const bitmap = await decodeImage(file);
  const scale = Math.min(1, 2200 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(bitmap.width * scale));
  canvas.height = Math.max(1, Math.round(bitmap.height * scale));
  const context = canvas.getContext("2d", { willReadFrequently: true });
  if (!context) throw new Error("This photo is too large to process on this device");
  context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close?.();
  const original = await new Promise(resolve => canvas.toBlob(resolve, "image/png"));
  if (!original) throw new Error("This photo could not be processed");
  const pixels = context.getImageData(0, 0, canvas.width, canvas.height);
  const histogram = new Uint32Array(256);
  for (let index = 0; index < pixels.data.length; index += 4) {
    histogram[Math.round(.3*pixels.data[index]+.59*pixels.data[index+1]+.11*pixels.data[index+2])]++;
  }
  const pixelCount = pixels.data.length / 4;
  function percentile(fraction) {
    const target = Math.floor(pixelCount * fraction);
    let count = 0;
    for (let value = 0; value < histogram.length; value++) {
      count += histogram[value];
      if (count > target) return value;
    }
    return 255;
  }
  const low = percentile(.05);
  const high = percentile(.95);
  const range = Math.max(35, high-low);
  for (let index = 0; index < pixels.data.length; index += 4) {
    const brightness = Math.round(.3*pixels.data[index]+.59*pixels.data[index+1]+.11*pixels.data[index+2]);
    const value = Math.max(0,Math.min(255,Math.round((brightness-low)*255/range)));
    pixels.data[index]=value;pixels.data[index+1]=value;pixels.data[index+2]=value;
  }
  context.putImageData(pixels,0,0);
  const enhanced = await new Promise(resolve => canvas.toBlob(resolve,"image/png"));
  if (!enhanced) throw new Error("This photo could not be processed");
  return {original,enhanced};
}

export async function recognizeImage(file) {
  if (!file.type.startsWith("image/")) throw new Error("Not an image");
  const worker = await prepareOCR();
  const {original, enhanced} = await resize(file);
  const candidates = [];
  async function read(image) {
    const { data } = await worker.recognize(image);
    const quality = assessOCR(data.text, data.confidence);
    candidates.push({ text:data.text.trim(), confidence:data.confidence, ...quality });
    return quality.accepted;
  }
  if (!await read(enhanced)) {
    if (!await read(original)) {
      // Sparse text mode can recover short notes positioned around a planner.
      await worker.setParameters({ tessedit_pageseg_mode: "11" });
      try { await read(original); }
      finally { await worker.setParameters({ tessedit_pageseg_mode: "3" }); }
    }
  }
  const chosen = candidates.filter(item => item.accepted).sort((a,b) => b.score-a.score)[0];
  if (!chosen) throw new Error("The photo text was not clear enough to use");
  return { text:chosen.text, confidence:chosen.confidence };
}
