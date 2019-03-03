#!/usr/bin/env bash

set -xeu

cd `git rev-parse --show-toplevel`

docker run --rm -it -v "$PWD":/workdir -w /workdir perl:5-slim perl _tools/_update-readme.pl
