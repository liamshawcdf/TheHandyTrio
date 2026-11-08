#!/usr/bin/env bash
git add -A
git commit -m "${1:-update}"
git push
