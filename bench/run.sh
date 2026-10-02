#!/bin/sh
# tests load on server in Lima
# save in bench/results/, tagged with git commit
#
# usage: bench/run.sh <name> [url]
#   bench/run.sh nginx http://localhost:8080/
set -eu

name=${1:?usage: bench/run.sh <name> [url]}
url=${2:-http://localhost:8080/}
vm=ziggurat
wrk_args="-t2 -c64 -d10s" # 2 threads, 64 connections, 10 seconds

bench_dir=$(cd "$(dirname "$0")" && pwd)
commit=$(git -C "$bench_dir" describe --always --dirty)
stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
out="$bench_dir/results/${stamp}_${commit}_${name}.txt"

if [ "$(limactl list --format '{{.Status}}' "$vm")" != Running ]; then
    echo "VM '$vm' isn't running. Start it with: limactl start $vm" >&2
    exit 1
fi

# warm up first, avoid cold cache
limactl shell "$vm" -- wrk -t2 -c64 -d2s "$url" > /dev/null

# $wrk_args split into separate flags
result=$(limactl shell "$vm" -- wrk $wrk_args --latency -s "$bench_dir/report.lua" "$url")

mkdir -p "$bench_dir/results"
{
    echo "name=$name"
    echo "url=$url"
    echo "commit=$commit"
    echo "date=$stamp"
    echo "wrk_args=$wrk_args"
    echo
    echo "$result"
} > "$out"

grep -E '^(requests_per_sec|p50_us|p99_us|errors)=' "$out"
echo "saved $out"
