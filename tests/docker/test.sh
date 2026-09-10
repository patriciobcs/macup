#!/bin/zsh
# Build the Linux test bench and run the script tests in it. Requires a Docker-compatible runtime.
# Usage: tests/docker/test.sh [--no-build]
set -eu
cd "$(dirname "$0")/../.."
[[ "${1:-}" == --no-build ]] || docker build -t macup-test -f tests/docker/Dockerfile .
docker run --rm -v "$PWD/Macup/Resources/Scripts:/home/dev/scripts:ro" -v "$PWD/tests/docker/run-tests.sh:/home/dev/run-tests.sh:ro" macup-test
