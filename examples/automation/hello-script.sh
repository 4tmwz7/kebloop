#!/bin/sh
# Select /bin/sh as runtime and this file's absolute path as the first argument.
printf 'Hello, %s!\n' "${1:-world}"
