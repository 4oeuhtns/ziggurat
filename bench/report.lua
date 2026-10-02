-- uses wrk to get statistics for nginx benchmark, in microseconds
done = function(summary, latency, requests)
  local e = summary.errors
  local seconds = summary.duration / 1e6
  io.write(string.format("requests_per_sec=%d\n", summary.requests / seconds))
  io.write(string.format("p50_us=%d\n", latency:percentile(50)))
  io.write(string.format("p99_us=%d\n", latency:percentile(99)))
  io.write(string.format("errors=%d\n", e.connect + e.read + e.write + e.status + e.timeout))
end
