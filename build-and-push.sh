#!/usr/bin/sh
docker buildx build --progress=plain -t git.kura.gg/kura/glitch-mastodon:latest -t git.kura.gg/kura/glitch-mastodon:4.7.2 --platform linux/amd64,linux/arm64 --push -f Containerfile .
