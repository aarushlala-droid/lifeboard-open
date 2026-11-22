// Mirrors web/tokens.css into web/tokens.json for a future native client.
// Run `node scripts/export-tokens.mjs`; `--check` fails when the JSON is stale.
import { readFileSync, writeFileSync } from 'node:fs';

const cssURL = new URL('../web/tokens.css', import.meta.url);
const jsonURL = new URL('../web/tokens.json', import.meta.url);

export function tokensFromCSS(css) {
  const source = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const blocks = { light: /:root\s*\{([^}]*)\}/, dark: /prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{([^}]*)\}/,
    increasedContrast: /prefers-contrast:\s*more\)\s*\{\s*:root\s*\{([^}]*)\}/,
    increasedContrastDark: /prefers-contrast:\s*more\)\s*and\s*\(prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{([^}]*)\}/ };
  const read = body => Object.fromEntries([...body.matchAll(/--lb-([\w-]+)\s*:\s*([^;]+);/g)].map(([, name, value]) => [name, value.trim()]));
  const result = {};
  for (const [name, pattern] of Object.entries(blocks)) {
    const match = source.match(pattern);
    if (!match) throw Error(`tokens.css is missing the ${name} block`);
    result[name] = read(match[1]);
  }
  const base = result.light;
  const group = prefix => Object.fromEntries(Object.entries(base).filter(([key]) => key.startsWith(prefix)).map(([key, value]) => [key, value]));
  const colourNames = Object.keys(result.dark);
  return {
    $schema: 'LifeBoard design tokens v1',
    source: 'mobile/web/tokens.css',
    colour: Object.fromEntries(colourNames.map(name => [name, {
      light: base[name], dark: result.dark[name],
      ...(result.increasedContrast[name] ? { lightIncreasedContrast: result.increasedContrast[name] } : {}),
      ...(result.increasedContrastDark[name] ? { darkIncreasedContrast: result.increasedContrastDark[name] } : {}),
    }])),
    font: group('font-'), size: group('size-'), weight: group('weight-'),
    space: { ...group('space-'), gutter: base.gutter, target: base.target, hour: base.hour },
    radius: group('radius-'), motion: { ...group('dur-'), ...group('ease-') },
  };
}

const json = `${JSON.stringify(tokensFromCSS(readFileSync(cssURL, 'utf8')), null, 2)}\n`;
if (process.argv.includes('--check')) {
  if (readFileSync(jsonURL, 'utf8') !== json) { console.error('web/tokens.json is stale: run node scripts/export-tokens.mjs'); process.exit(1); }
  console.log('tokens.json matches tokens.css');
} else if (import.meta.url === `file://${process.argv[1]}`) {
  writeFileSync(jsonURL, json);
  console.log('Wrote web/tokens.json');
}
