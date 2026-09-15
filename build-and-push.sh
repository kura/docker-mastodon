#!/usr/bin/sh
ver=$(curl -sf "https://api.github.com/repos/glitch-soc/mastodon/releases/latest"  | awk '/tag_name/{print $4;exit}' FS='[""]' | sed 's/v//g')
docker buildx build --progress=plain -t git.kura.gg/kura/glitch-mastodon:latest -t "git.kura.gg/kura/glitch-mastodon:$ver" --platform linux/amd64,linux/arm64 --push -f Containerfile .
