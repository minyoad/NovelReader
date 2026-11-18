#!/usr/bin/env python3
"""对比 iPhone 13 与 iPhone 17 的书架和书源，确认两台一致、没有重复书目。"""
import json
import collections


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def show(label, books, sources):
    print(f"=== {label} ===")
    if books is None:
        print("  books.json 不存在")
        return
    print(f"  书架 {len(books)} 本, 书源 {len(sources) if sources is not None else '?'} 个")
    by_name = collections.defaultdict(list)
    for b in books:
        by_name[b.get("name", "")].append(b)
    dups = {k: v for k, v in by_name.items() if len(v) > 1}
    if dups:
        print("  ⚠ 重复书名:")
        for name, items in dups.items():
            print(f"    【{name}】×{len(items)}")
            for b in items:
                p = b.get("progress", {})
                print(f"      ch={p.get('chapterIndex')} url={b.get('detailURL')}")
    else:
        print("  ✓ 无重复书名")
    print("  书单:")
    for name, items in by_name.items():
        p = items[0].get("progress", {})
        ch = p.get("chapterIndex", 0)
        print(f"    {name}  第{ch}章")
    print()


b13 = load("/tmp/cmp13/books.json")
s13 = load("/tmp/cmp13/sources.json")
b17 = load("/tmp/cmp17/books.json")
s17 = load("/tmp/cmp17/sources.json")

show("iPhone 13", b13, s13)
show("iPhone 17", b17, s17)

if b13 is not None and b17 is not None:
    n13 = {b.get("name") for b in b13}
    n17 = {b.get("name") for b in b17}
    print("=== 差异 ===")
    print("  只在 13 上:", sorted(n13 - n17) or "无")
    print("  只在 17 上:", sorted(n17 - n13) or "无")
