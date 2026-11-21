// Tesseract's page confidence can be high even when it has read a photograph as
// scattered letters. Check whether the result looks like lines of useful text
// before offering it as task input.
export function assessOCR(text, confidence) {
  const lines = text.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  const substantial = lines.filter(line => {
    const words = line.match(/[\p{L}]{2,}/gu) || [];
    const letters = (line.match(/\p{L}/gu) || []).length;
    return words.length >= 2 && letters >= 7 && letters / Math.max(line.length, 1) >= 0.58;
  }).length;
  const ratio = lines.length ? substantial / lines.length : 0;
  const accepted = Number.isFinite(confidence) && confidence >= 50 && substantial >= 1 &&
    (lines.length <= 2 || (lines.length <= 8 ? substantial >= 2 : ratio >= 0.55));
  return { accepted, score: ratio * 55 + Math.min(Math.max(confidence, 0), 100) * 0.45, lines: lines.length };
}
