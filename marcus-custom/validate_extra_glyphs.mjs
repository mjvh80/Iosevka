import assert from "node:assert/strict";
import fs from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { FontIo, Ot } from "ot-builder";
import harfbuzz from "harfbuzzjs";

const [sourcePath, resultPath] = process.argv.slice(2);
assert(sourcePath && resultPath, "Usage: node validate_extra_glyphs.mjs SOURCE.ttf RESULT.ttf");
const sourceBytes = fs.readFileSync(sourcePath);
const resultBytes = fs.readFileSync(resultPath);
const sourceSfnt = FontIo.readSfntOtf(sourceBytes);
const resultSfnt = FontIo.readSfntOtf(resultBytes);
const source = FontIo.readFont(sourceSfnt, Ot.ListGlyphStoreFactory);
const result = FontIo.readFont(resultSfnt, Ot.ListGlyphStoreFactory);
const sourceOrder = source.glyphs.decideOrder();
const resultOrder = result.glyphs.decideOrder();
const resultsByName = new Map();
for (const glyph of resultOrder) {
    if (!resultsByName.has(glyph.name)) resultsByName.set(glyph.name, []);
    resultsByName.get(glyph.name).push(glyph);
}

for (const glyph of sourceOrder) {
    const candidate = resultsByName.get(glyph.name)?.shift();
    assert(candidate, `Missing original glyph: ${glyph.name}`);
    assert(isDeepStrictEqual(candidate.geometry, glyph.geometry), `Changed outline: ${glyph.name}`);
    assert.deepEqual(candidate.horizontal, glyph.horizontal, `Changed advance: ${glyph.name}`);
    assert.deepEqual(candidate.hints, glyph.hints, `Changed hints: ${glyph.name}`);
}
for (const [codepoint, glyph] of source.cmap.unicode.entries()) {
    assert.equal(result.cmap.unicode.get(codepoint)?.name, glyph.name, `Changed mapping: U+${codepoint.toString(16)}`);
}
for (const tag of ["name", "fpgm", "prep", "cvt ", "gasp"]) {
    assert.deepEqual(resultSfnt.tables.get(tag), sourceSfnt.tables.get(tag), `Changed table: ${tag}`);
}
assert.deepEqual(result.os2, source.os2, "Changed OS/2 metrics or style fields");
const zero = result.cmap.unicode.get(0x30);
const expectedAdvance = 2 * (zero.horizontal.end - zero.horizontal.start);
for (const key of Object.keys(source.hhea)) {
    if (key === "advanceMax") {
        assert.equal(result.hhea[key], Math.max(source.hhea[key], expectedAdvance));
    } else if (key !== "numberOfLongMetrics") {
        assert.deepEqual(result.hhea[key], source.hhea[key], `Changed hhea field: ${key}`);
    }
}
assert.equal(result.head.unitsPerEm, source.head.unitsPerEm);
for (const codepoint of [0x30c4, 0x30b7, 0x30c3]) {
    const glyph = result.cmap.unicode.get(codepoint);
    assert(glyph?.geometry, `Missing added outline: U+${codepoint.toString(16)}`);
    if (!source.cmap.unicode.get(codepoint)) {
        assert.equal(glyph.horizontal.end - glyph.horizontal.start, expectedAdvance);
    }
}

const hb = await harfbuzz;
function createShaper(bytes, glyphOrder) {
    const blob = hb.createBlob(bytes);
    const face = hb.createFace(blob, 0);
    const font = hb.createFont(face);
    return {
        shape(text, features) {
            const buffer = hb.createBuffer();
            try {
                buffer.addText(text);
                buffer.guessSegmentProperties();
                hb.shape(font, buffer, features);
                return buffer.json().map(({ g: glyphId, ...position }) => ({
                    glyph: glyphOrder.at(glyphId).name,
                    ...position,
                }));
            } finally {
                buffer.destroy();
            }
        },
        close() {
            font.destroy();
            face.destroy();
            blob.destroy();
        },
    };
}
const before = createShaper(sourceBytes, sourceOrder);
const after = createShaper(resultBytes, resultOrder);
const samples = [
    "Hello world 0123456789", "!= !== === == <= >= -> => <=> <-- -->",
    ":: ::: ... .. ++ -- ___ && || /* */ // </> <!-- -->",
    "fi fl ffi ffl ->> >>= <<= <| |> <|| ||>",
    "a\u0301 e\u0308 i\u0307 A\u030a \u00e5\u00e4\u00f6 \u03bb\u03bc",
    "\ue0b0 \ue0b1 \uf013 \uf07b \uf08d0",
];
const features = new Set(["", "calt=0,liga=0,dlig=0", "calt=1,liga=1,dlig=1", "ss01=1"]);
for (const feature of source.gsub?.features ?? []) {
    features.add(`calt=0,${feature.tag}=1`);
}
let comparisons = 0;
try {
    for (const feature of features) {
        for (const text of samples) {
            assert.deepEqual(after.shape(text, feature), before.shape(text, feature), `Changed shaping: ${feature} ${text}`);
            comparisons++;
        }
    }
} finally {
    before.close();
    after.close();
}
console.log(JSON.stringify({
    font: resultPath,
    originalGlyphsUnchanged: [...sourceOrder].length,
    shapingComparisons: comparisons,
    extraGlyphAdvance: expectedAdvance,
    status: "PASS",
}));