#! /usr/bin/env bash

pandoc -s -f markdown+fenced_divs --highlight-style haddock --self-contained --css pandoc.css index.md -o index.html
chmod 644 index.html
