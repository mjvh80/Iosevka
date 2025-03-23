import fontforge
import sys
import os
import re


first = sys.argv[1]
second = sys.argv[2]

print ("first = " + first)
print ("second = " + second)


output_font_dir = R"D:\git\Iosevka\dist\iosevka-marcus-cond\ttf"

for file in [first, second]:
    font = fontforge.open(file)

    print("")
    print ("Font: " + file)

    print ("fullname = " + font.fullname)
    print ("familyname = " + font.familyname)
    print ("fontname = " + font.fontname)

    print ("em = " + str(font.em))
    print ("sfnt revision = " + str(font.sfntRevision))

    for item in font.sfnt_names:
        print (item)

    print("")

