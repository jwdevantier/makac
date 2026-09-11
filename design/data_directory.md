The data directory for this project should be `.makac`, mirroring the tool's name.

The data directory should be local to the user's project and reside in their project's root folder.
When the `makac` tool is invoked, we look for the data directory like so:
1. look in CWD for `.makac` folder, if not, continue
2. look in CWD for `.git` folder, if not, continue
3. look in parent directory, loop to step 1

* Iff we encounter a `.git` folder, but no `.makac` folder, create it.
  * (we automatically create the `.makac` data directory folder, if we can determine where it should be)
* Iff we encounter neither and reach the top-level/root directory, error out, telling the user that we could not determine the root of their project and that THEY must initialize the makac data directory (see design/cli.md)

