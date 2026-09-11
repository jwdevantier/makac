The shell action is a specific type of action. It runs a shell command either locally on the host, or if given a `target` argument, on the remote target.


```lua
step {
  name = "do a thing",
  uses = "shell",
  with = {
    -- command to run
    cmd = {"cat", "/etc/resolv.conf"},
    -- optional, defaults to running in $HOME of user
    chdir = "/home/pseud",
    -- optional, shell used to run the command on a remote target;
    -- defaults to /bin/sh (see the note below for why)
    shell = "/bin/sh",

    -- optional, defaults to running directly on HOST
    target = ...,

    -- optional, additional environment variables to set before command execution
    env = {
      THING = "true",
      OTHER_THING = "bad",
    },

    -- optional, data to write to the command's stdin (non-interactive)
    stdin = ...,

    -- optional, bool: merge stderr into stdout (the shell's 2>&1),
    -- preserving true interleaved order; out.stderr then comes back empty.
    -- On remote targets this appends `2>&1` to the command line.
    join = false,

    -- optional, number (seconds): kill the command when it overruns
    -- (SIGTERM, 1s grace, SIGKILL); out.timed_out is set. Host only for now
    -- (not supported on remote targets).
    timeout_s = 30,

    -- optional, function(line, stream): called with each COMPLETE line as it
    -- arrives (stream is "stdout"/"stderr"); the full capture is still
    -- returned. A raising callback aborts the command and fails the step.
    -- Host only for now. Use for progress: e.g. io.stderr:write(line, '\n')
    on_line = nil,

    -- optional, bool, whether to avoid raising error on exit code != 0
    --           false by default
    ignore_exit_code = false
  }
}
```

### The `shell` argument

`shell` selects the shell used to run the command. It defaults to `/bin/sh`.

The argument exists because, over SSH, a command is executed under the remote
user's *login* shell, which is arbitrary — fish, zsh, or anything else — and
need not be POSIX. Setting environment variables relies on POSIX assignment
syntax (`NAME=value command ...`), which non-POSIX shells do not share.
Rather than depend on that, makac always invokes `shell` explicitly:

    shell -c "<env assignments> <argv>"

so the env assignments are interpreted by a shell makac chose, deterministically
and independent of whatever the login shell happens to be.

On the host there is no login shell in the way — the command is spawned
directly with the environment passed as a separate vector — so `shell` has no
effect locally. It only matters when a `target` is given.

## Returns
The shell action returns the same kind of associative table as any action. Below shows the specifics of how the values should be set.

```lua
{
  -- set iff exitcode != 0 AND ignore_exit_code is false
  err = ""
  -- will always be true for a shell command (conservative assumption)
  changed = true,

  out = {
    -- string: stdout, captured separately from stderr
    stdout = "",
    -- string: stderr
    stderr = "",
    -- string: stdout then stderr joined, for when a single string is more
    --         convenient (joining is lossy and always optional; with
    --         join=true the stdout field itself is the true interleaving)
    output = "",

    -- int: program exit code
    code = 0,

    -- bool: true iff the command was killed by timeout_s
    timed_out = false
  }
}
```


