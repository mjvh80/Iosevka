import fontforge
import sys
import os
import re
from pprint import pprint

font_dir = R"D:\git\Iosevka\marcus-custom\cascadia_code"

output_dir = R"D:\git\Iosevka\marcus-custom\cascadia_frozen"

if not os.path.exists(output_dir):
    os.makedirs(output_dir)

for root, dirs, files in os.walk(font_dir):
    for file in files:
        font = fontforge.open(os.path.join(root, file))

        # freeze ss01 feature
        ss01_lookup = None
        for lookup in font.gsub_lookups:
            if 'ss01' in lookup:
                tables = font.getLookupSubtables(lookup)
                ss01_lookup = tables[0] # todo not sure if we can more
                break

        print ("Font: " + file + " found lookup " + str(ss01_lookup))

        if ss01_lookup is not None:
            for glyph in font.glyphs():
                subs = glyph.getPosSub(ss01_lookup)
                if subs:
                    for sub in subs:
                        if sub[1] == 'Substitution':
                            orig = glyph.glyphname
                            repl = sub[2]
                            
                            # Replace outline
                            font[orig].clear()
                            font[orig].addReference(repl)
                            font[orig].unlinkRef()

                            # Correctly preserve metrics
                            font[orig].width = font[repl].width
                            

        font.generate(os.path.join(output_dir, file))

        print("")