import fontforge
import sys
import os
import re


output_font_dir = R"D:\git\Iosevka\dist\iosevka-marcus-cond\ttf"

for root, dirs, files in os.walk(output_font_dir):
    for file in files:
        font = fontforge.open(os.path.join(root, file))

        print ("Font: " + file)

        print ("fullname = " + font.fullname)
        print ("familyname = " + font.familyname)
        print ("fontname = " + font.fontname)

        print ("em = " + str(font.em))
        print ("sfnt revision = " + str(font.sfntRevision))

        for item in font.sfnt_names:
            print (item)

        print("")

