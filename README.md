# mbt-stc

A plugin for [MBT (mbt)](https://github.com/mvslovers/mbt) 3 that restarts a
project's started task on MVS 3.8j and **compresses its development library
on the way**.

## Why

`mbt deploy` puts new load modules into the project's development library
(`NAME.DEV.LINKLIB`) by replacing members, so a running server keeps the
library open while it is deployed into. A replaced member's old space is not
freed, though: it stays dead until the library is compressed, and every deploy
uses more of the library. A compress needs the library to itself, which only
happens while the server is down. The moment to compress is therefore the
restart that activates the new modules anyway.

## Quick start

Declare the plugin in `mbt.toml`:

```toml
[plugins]
"mvslovers/mbt-stc" = "^0.1"
```

Then `mbt deps`, and after a deploy:

```
$ mbt deploy
$ mbt run restart
```

`mbt run restart` names the started task after the project (`ufsd` → `UFSD`).
Give another name after `--`:

```
$ mbt run restart -- HTTPD
```

`mbt run --dry-run restart` shows what it would do and touches nothing.

## What it does

1. **Submits a compress job** (`IEBCOPY`, `COPY OUTDD=LIB,INDD=LIB`) for the
   project's deploy target. The job asks for the library `DISP=OLD`. While the
   server holds it, MVS lets the job wait (`IEF099I ... WAITING FOR DATA
   SETS`).
2. **Stops the server** with `P <STC>`. Once it has ended, the job gets the
   library and compresses it.
3. **Starts the server** with `S <STC>`. The new server asks for its
   `STEPLIB` and waits in the same way until the compress is done.

MVS's data set queue does the waiting, so the command itself never polls.
If the stop cannot be issued, the waiting job is cancelled (`C MBTCOMP`)
before the command fails, so it does not hold an initiator indefinitely.

The job is submitted *before* the stop on purpose. A server that carries the
REST API with it, such as HTTPD running mvsMF, takes the submit path down
when it stops. The operator commands then fall back to the next console
channel of the target (the Hercules web console) by themselves.

## Requirements

- MBT 3.0.0-dev of 2026-10-10 or later. The command reads the library from
  `ctx.project.deploy_target`.
- A target (`~/.mbt/targets.toml`) with mvsMF for the submit. For a server
  that is mvsMF's own host, the target also needs a second console channel,
  `[target.NAME.hercules]`.
- A job class with a free initiator for the target's `jobclass`. The compress
  job occupies it for the few seconds between submit and compress.
- Nothing installed on MVS: no procedure, no PARMLIB member.

## Limits

- The started task must take its development library from `STEPLIB`, like
  every server in the ecosystem, and nothing else may hold the library while
  the server is down.
- The command restarts the server whether or not anything was deployed. It
  is meant for the restart that follows a deploy.

## Licence

MIT, see [LICENSE](LICENSE).
