"""Silhouette-locked art swap: take a nano-banana edit of an existing sprite,
resize it to the original's dimensions, and re-apply the ORIGINAL alpha
channel so the sprite's silhouette (and every rig anchor measured from it)
stays byte-identical. Usage:

    python3 apply_alpha.py <edited.png> <original.png> <dest.png>
"""
import sys
from PIL import Image

def main():
    edited, original, dest = sys.argv[1:4]
    orig = Image.open(original).convert('RGBA')
    ed = Image.open(edited).convert('RGB').resize(orig.size, Image.LANCZOS)
    out = ed.convert('RGBA')
    out.putalpha(orig.split()[3])
    out.save(dest)
    print(f"{dest} {out.size}")

main()
