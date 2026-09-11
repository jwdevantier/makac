This directory describes the design of makač (cli program: makac), an informal Czech word
for a hard worker or grinder.

Makac attempts to be a orchestrator/runner - somewhat between a "CI" and a test-runner system.
Stylistically, it is a cross of a GitHub Actions-style CI runner with Ansible-esque (declarative) actions, but rooted firmly as a DSL in plain Lua rather than YAML.

## Ansible-esque features
- workflow (close to an Ansible playbook)
- actions (close to GitHub Actions or Ansible modules)
- target (~host abstraction - allows a way to send commands and files to- or download files FROM a host)

## Unique choices
- is a Lua DSL
- actions shall be implemented in Lua, running on the HOST while gathering information or affecting the state of a remote host is done via shell commands and file transfers instigated through the target abstraction.


