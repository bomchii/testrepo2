#!/usr/bin/env python3
"""Aplica los parches de un experimento a una COPIA del front-end de Twoyi.

Cada parche es un reemplazo literal {search, replace, count} sobre
index.html o neo-web.js. Falla en voz alta si el texto no aparece el
numero exacto de veces esperado: un parche que no aplica en silencio
falsearia el experimento entero.

Uso:
  python3 scripts/opt-apply-patches.py --front-dir <dir> --config <config.json>
"""
import argparse
import glob
import json
import os
import sys


def apply_one(path, search, replace, expected, label):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()
    n = text.count(search)
    if n != expected:
        print(f"FALLO {label}: '{search[:60]}...' aparece {n} veces en {path}, se esperaban {expected}")
        return False
    text = text.replace(search, replace)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)
    print(f"OK {label}: {n}x '{search[:60]}' -> '{replace[:60]}' en {os.path.basename(path)}")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--front-dir", required=True)
    ap.add_argument("--config", required=True)
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)

    index_html = os.path.join(args.front_dir, "index.html")
    neo_files = glob.glob(os.path.join(args.front_dir, "rt", "*", "neo-web.js"))
    if not os.path.isfile(index_html):
        print("FALLO: no existe index.html en", args.front_dir)
        return 1
    if len(neo_files) != 1:
        print("FALLO: neo-web.js no encontrado o ambiguo:", neo_files)
        return 1
    neo_js = neo_files[0]

    ok = True
    applied = []
    for p in cfg.get("index_patches", []):
        if not apply_one(index_html, p["search"], p["replace"], p.get("count", 1), "index.html"):
            ok = False
        else:
            applied.append(f"index.html: {p['search'][:50]} -> {p['replace'][:50]}")
    for p in cfg.get("neo_patches", []):
        if not apply_one(neo_js, p["search"], p["replace"], p.get("count", 1), "neo-web.js"):
            ok = False
        else:
            applied.append(f"neo-web.js: {p['search'][:50]} -> {p['replace'][:50]}")

    with open(os.path.join(args.front_dir, "PATCHES-APPLIED.txt"), "w", encoding="utf-8") as f:
        f.write(f"Experimento {cfg.get('id')}: {cfg.get('name')}\n")
        f.write("\n".join(applied) if applied else "(sin parches)\n")
        f.write("\n")

    if not ok:
        print("PARCHES INCOMPLETOS: el experimento no debe correr con el front-end a medias.")
        return 1
    print("Parches aplicados correctamente.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
