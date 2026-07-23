# Project agent instructions

## Benchmarking

- Optimize for fast iteration. Use short benchmark runs by default while
  developing or comparing early ideas.
- A normal performance iteration should run for roughly 8–10 seconds and test
  only the thread count or configuration relevant to the current change.
- Use a roughly 5-second run only as a smoke test for crashes or startup
  failures; do not treat it as a reliable performance measurement.
- Do not run full thread-count sweeps or sustained thermal tests after every
  change.
- Once a candidate shows a meaningful improvement, confirm it with 30–60
  second comparisons against the baseline.
- Never run a sustained thermal test without the user's explicit approval.
- With approval, reserve 10–20 minute sustained tests, power/thermal analysis,
  and complete thread-count sweeps for strong candidates or final validation.
- Before recording a result, verify that no older miner processes are still
  running and competing for CPU time.
- Record the exact build flags, thread count, duration, hardware, and result
  for any benchmark used to make a decision.
