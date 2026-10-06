# enrollment

One consumer per downstream system, each converging its own system towards the
inventory projection it was handed. No orchestrator, no ordering, no shared
state.

```
inventory.csv
   └── ../inventory/projections/project.py
         ├── intune.csv  ──> intune-gitops: consumers/intune.py   builds the group ladder
         ├── cimian.csv  ──> consumers/cimian.py                  publishes computers.csv
         └── mdm.csv     ──> your Autopilot routing (no consumer ships here)
```

The shared parts (the naming convention, the Graph client, the guards, the
Intune group-ladder consumer and the triggers) live in
[windowsadmins/intune-gitops](https://github.com/windowsadmins/intune-gitops/tree/v0.1.2/enrollment),
together with their tests and the reasoning behind the guards. This directory
keeps only the Cimian consumer, which imports `shared/` from there.

[munki-gitops](https://github.com/rodchristiansen/munki-gitops) runs the same
projection for its macOS rows.

## Setting up the path

Check intune-gitops out beside this repo at the tag the pipelines pin:

```
git clone --branch v0.1.2 https://github.com/windowsadmins/intune-gitops ../intune-gitops
```

Then put both enrollment directories on `PYTHONPATH`, **this repo's first**.
Both repos have a `consumers` package; this one extends its path to include
the intune-gitops one, which only works when it is found first:

```
export PYTHONPATH="$PWD/enrollment:$PWD/../intune-gitops/enrollment"
```

## Running one

Everything plans before it writes. Project the inventory, then plan each
consumer:

```
python3 inventory/projections/project.py inventory/inventory.csv --out-dir out/
```

```
python3 -m consumers.cimian out/cimian.csv --what-if
```

```
python3 -m consumers.intune out/intune.csv --what-if
```

With no `GRAPH_TOKEN` set, the Intune consumer prints the group plan and stops
without making a single call. That is the first thing to run after forking:
look at the ladder it would build before giving it credentials.

The Cimian consumer refuses a projection whose header is not the published
column order, or with fewer rows than `CIMIAN_MIN_ROWS`. Its publish steps
(push `computers.csv` to the repo host, upload it, purge the CDN path) are left
as integration points for your own hosting.

| Variable | Default | Meaning |
|---|---|---|
| `CIMIAN_COMPUTERS_CSV_PATH` | `deployment/enroll/computers.csv` | Where the projection is published |
| `CIMIAN_MIN_ROWS` | `1` | Floor below which the projection is refused; set it from your fleet size |

## Triggers

The intune-gitops triggers (an Azure Functions blob trigger and a signed
generic webhook) reach the built-in `intune` consumer. Register the Cimian one
by name, with the `PYTHONPATH` above:

```
export ENROLLMENT_CONSUMERS="cimian=consumers.cimian:converge"
```

Since v0.1.2 the intune-gitops `consumers` package extends its path, so
`consumers.cimian` resolves from inside a trigger as well as when run directly.

## Tests

With `PYTHONPATH` set as above:

```
python3 -m unittest discover -s enrollment/tests -v
```

They cover the header check, the row floor, whatIf, and that `cimian`
registers beside the shared `intune` consumer. The group-ladder tests run in
intune-gitops.
