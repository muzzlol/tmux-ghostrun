#!/usr/bin/env bash

# Emit one ASCII spinner frame based on current epoch second.
n=$(date +%s)
case $((n % 4)) in
    0) printf '|' ;;
    1) printf '/' ;;
    2) printf '-' ;;
    3) printf '\\' ;;
esac
