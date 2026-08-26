# What the test bench measures, and what it doesn't

## The three metrics

**TTFT — time to first token.** The delay between the HTTP request and the first
useful word. It includes: network, server queue, any model loading, and the first
compute pass over the prompt. It is the metric that decides whether an engine can sit
behind an interface where someone is waiting.

**Tokens per second.** Computed on the generation phase only: `tokens / (total − TTFT)`.
Excluding the TTFT matters, otherwise an engine that is slow to start but fast to
generate would look worse than it is.

**Total time.** TTFT plus generation. It is the number that counts for a deferred
job, where nobody is watching the screen.

## Why p50 and p95

With few runs the median (p50) is the representative value; the p95 tells you whether
there is variability. Over three runs the p95 is not statistics: it is a warning
light. If p95 and p50 are far apart, something in the system is not stable — almost
always it's the page cache emptying, or another process that took the memory.

## What it does NOT measure

- **The quality of the answers.** The test bench measures times, not content.
- **The behavior under real load.** `concurrency` fires N requests together, but a
  real load has prompts of varying lengths and irregular arrivals.
- **Power consumption.**
- **The correctness of the gateway routing.** It checks that it responds, not that it
  picked the right engine: for that, compare the returned `model`.

## The comparison that matters most

The same model, measured **through the gateway** and **directly against the engine**.
The difference is the router's cost. If it is a few milliseconds, fine; if it is
seconds, the problem is in the gateway configuration, not in the model.

## Before and after

Use the **label** field: every run ends up in the history with that text. Useful
examples: `baseline`, `after 128GB RAM`, `with cgroup on the containers`, `stripe on
two disks`, `after cold restart`. The value of this tool is not the absolute number —
it is the difference between two configurations on the same machine.

## A warning about the cache

The first run after a restart is always the slowest: the page cache is empty and
every part of the model comes from disk. The following ones are faster because a slice
of the model is already in RAM. If you want to measure the worst case, measure the
first run; if you want to measure steady state, discard the first and keep the rest.
