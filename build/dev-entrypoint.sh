#!/bin/sh
# 开发容器入口：准备运行时目录，按需预置外置扫描器，然后交给 air/dlv
set -eu

mkdir -p /apps/ext /apps/config /apps/data /apps/dictionaries \
         /apps/poc /apps/plugin /apps/tmp

# 程序以「可执行文件所在目录」为根，/apps 下的目录在 compose 里是命名卷
if [ "$(uname -m)" = "x86_64" ] && [ -z "$(ls -A /apps/ext 2>/dev/null)" ]; then
    for tool in rad ksubdomain rustscan katana; do
        if [ -f "/opt/tools/linux/$tool" ]; then
            mkdir -p "/apps/ext/$tool"
            cp "/opt/tools/linux/$tool" "/apps/ext/$tool/$tool"
            chmod +x "/apps/ext/$tool/$tool"
        fi
    done
    echo "[dev] 已从 /opt/tools/linux 预置外置扫描器到 /apps/ext"
fi

exec "$@"
