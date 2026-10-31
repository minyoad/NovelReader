#!/bin/bash
set -e
cd /home/yang/ios/NovelReader
git add -A
git commit -q -F - <<'MSG'
Reader chrome: one top slot, labelled bottom bar

The tap-to-reveal toolbar duplicated the chapter title that the header
already showed, and both were squeezed to one line each, so long Chinese
chapter titles truncated twice. The header also reserved a separate band
above the toolbar, leaving an empty strip while the bar was up.

- Chapter title and toolbar now share one fixed 44pt slot: the page never
  re-flows when the bars appear, and the toolbar no longer sits below a
  redundant title line.
- Toolbar keeps only dismiss, the title and a menu; TOC, source, cache, AI
  and settings moved into the menu, giving the title the full width.
- Bottom bar: five labelled cells instead of three sparse icons, with
  TOC and cache added. Icon box is a shared constant so the filled play
  button sits on the same baseline as its neighbours.
- PagedReader reports the page position through a binding; the footer that
  held it is gone and its 30pt now belongs to the text.
MSG
git log --oneline -1
