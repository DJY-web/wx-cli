#!/bin/sh
# All account data stays in Docker; never mount the Mac WeChat directories.
set -eu
cd "$(dirname "$0")/.."
if command -v docker >/dev/null 2>&1; then
    docker_bin=$(command -v docker)
else
    docker_bin=/Applications/Docker.app/Contents/Resources/bin/docker
fi
if [ ! -x "$docker_bin" ]; then
    echo "Docker is not installed/running." >&2
    exit 1
fi
PATH="$(dirname "$docker_bin"):$PATH"
export PATH
wechat_container=${WX_CLI_WECHAT_CONTAINER:-wechat-mercari-assistant-wechat-1}
wechat_volume=${WX_CLI_WECHAT_VOLUME:-wechat-mercari-assistant_wechat-config}
state_volume=${WX_CLI_STATE_VOLUME:-wx-cli-linux-state}
image=${WX_CLI_LINUX_IMAGE:-wx-cli-linux:local}
action=${1:-help}
if [ "$#" -gt 0 ]; then shift; fi
case "$action" in
    build)
        exec "$docker_bin" build -f docker/Dockerfile -t "$image" .
        ;;
    scan)
        # SYS_PTRACE exists only for this short-lived helper in the desktop's
        # PID namespace. Database mount is read-only, network is disabled.
        exec "$docker_bin" run --rm --name wx-cli-linux-scan --network none --user 0 --pid="container:$wechat_container" \
            --cap-add SYS_PTRACE --read-only --tmpfs /tmp \
            --mount "type=volume,source=$wechat_volume,target=/config,readonly" \
            --mount "type=volume,source=$state_volume,target=/state" \
            --entrypoint /bin/sh "$image" -c 'wx-cli key scan && chown -R 1000:1000 /state'
        ;;
    capture)
        # Explicit opt-in: debugger capture can pause WeChat briefly and requires
        # a manual sign-out/sign-in. It is never part of normal server startup.
        capture_image=${WX_CLI_CAPTURE_IMAGE:-wx-cli-linux-capture:local}
        exec "$docker_bin" run --rm --name wx-cli-linux-capture --network none --user 0 --pid="container:$wechat_container" \
            --cap-add SYS_PTRACE --read-only --tmpfs /tmp \
            --mount "type=volume,source=$wechat_volume,target=/config,readonly" \
            --mount "type=volume,source=$state_volume,target=/state" \
            --entrypoint /bin/sh "$capture_image" -c 'wx-cli key extract --timeout 600 && chown -R 1000:1000 /state'
        ;;
    run)
        exec "$docker_bin" run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp \
            --mount "type=volume,source=$wechat_volume,target=/config,readonly" \
            --mount "type=volume,source=$state_volume,target=/state" "$image" "$@"
        ;;
    server)
        if "$docker_bin" container inspect wx-cli-linux-api >/dev/null 2>&1; then
            exec "$docker_bin" start wx-cli-linux-api
        fi
        exec "$docker_bin" run -d --init --name wx-cli-linux-api --restart unless-stopped \
            --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp \
            -p 127.0.0.1:9100:9100 \
            --mount "type=volume,source=$wechat_volume,target=/config,readonly" \
            --mount "type=volume,source=$state_volume,target=/state" \
            --entrypoint /usr/local/bin/wx-cli-server "$image"
        ;;
    stop)
        exec "$docker_bin" stop wx-cli-linux-api
        ;;
    *)
        echo "Usage: sh scripts/selkies.sh build | scan | capture | run <wx-cli args> | server | stop"
        echo "Existing encryption keys are required for queries; failed scans are not success."
        ;;
esac
