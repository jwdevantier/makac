-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause

---@meta
---@diagnostic disable: missing-fields, lowercase-global
-- LuaCATS definitions for makac's injected globals and Lua stdlib extensions
-- (design/luacats.md). This file is embedded in the binary and installed into
-- a project's data directory by makac.luals_setup(); it is definitions-only
-- and is never executed.

-- --- shell / processes ----------------------------------------------------

---@class RunResult
---@field code integer
---@field stdout string
---@field stderr string

---@class RunOpts
---@field cwd? string
---@field env? table<string, string>
---@field stdin? string
---@field join? boolean
---@field timeout_s? number
---@field on_line? fun(line: string, stream: string)

---@class SpawnOpts
---@field stdout? string
---@field stderr? string
---@field chdir? string
---@field env? table<string, string>

---@class Proc
local Proc = {}

---@type integer
Proc.pid = 0

---@return "running"|{ code: integer }
function Proc:status() end

-- --- targets (design/target.md) -------------------------------------------

---@class SshSpec
---@field host string
---@field user string
---@field port? integer
---@field options? table<string, any>

---@class Target
local Target = {}

---@param cmd string|string[]
---@param opts? RunOpts
---@return RunResult
function Target:run(cmd, opts) end

---@param src string
---@param dst string
function Target:put(src, dst) end

---@param src string
---@param dst string
function Target:get(src, dst) end

-- --- makac.fs (design/stdlib.md) ------------------------------------------

---@class FsEntry
---@field name string
---@field is_dir boolean

---@class FsStat
---@field type "file"|"dir"|"socket"|"link"|"other"
---@field size integer
---@field mtime_ns integer

---@class Path
local Path = {}

---@return string
function Path:__tostring() end

---@return Path
function Path:dirname() end

---@return string
function Path:basename() end

---@param ... string|Path
---@return Path
function Path:join(...) end

---@class Dir
local Dir = {}

---@return Path
function Dir:path() end

---@param sub? string
---@return boolean
function Dir:exists(sub) end

---@param sub? string
function Dir:touch(sub) end

---@param sub? string
function Dir:make_path(sub) end

---@param sub? string
---@return Dir
function Dir:open_dir(sub) end

---@return Dir
function Dir:parent() end

---@return FsEntry[]
function Dir:list() end

---@return fun(): string?, string?
function Dir:walk() end

---@param sub? string
function Dir:remove(sub) end

---@class MakacFs
---@field sep string
---@field path fun(s: string|Path): Path
---@field path_join fun(a: string|Path, b: string|Path, ...: string|Path): Path
---@field null_file fun(): Path
---@field cwd fun(): Dir
---@field open_dir fun(path: string|Path): Dir
---@field listdir fun(path: string|Path): FsEntry[]|nil, string?
---@field mkdir_p fun(path: string|Path)
---@field read_file fun(path: string|Path): string|nil, string?
---@field write_file fun(path: string|Path, data: string, opts?: { atomic?: boolean })
---@field stat fun(path: string|Path): FsStat|nil
---@field mktemp_dir fun(prefix?: string): Path
---@field mktemp_file fun(prefix?: string): Path
---@field sha256 fun(path: string|Path): string|nil, string?
---@field symlink fun(target: string|Path, link: string|Path)

-- --- makac.time / makac.env / makac.json ----------------------------------

---@class MakacTime
---@field now fun(): integer
---@field sleep fun(ns: integer)
---@field ns_per_us integer
---@field ns_per_ms integer
---@field ns_per_s integer

---@class MakacEnv
---@field all fun(): table<string, string>
---@field version fun(): integer, integer
---@field makac_path fun(): Path

---@class MakacJson
---@field dumps fun(value: any): string
---@field loads fun(s: string): any

-- --- the makac global ------------------------------------------------------

---@class Makac
---@field data_dir string
---@field exec fun(argv: string[], opts?: RunOpts): RunResult
---@field spawn fun(argv: string[], opts?: SpawnOpts): Proc
---@field pid_alive fun(pid: integer): boolean
---@field random_hex fun(n: integer): string
---@field download fun(url: string, sha256?: string, cache_dir?: string): string
---@field ssh_open fun(name: string, spec: any): Target
---@field new_ssh_target fun(name: string, spec: SshSpec): Target
---@field qmp_open fun(vm: any): any
---@field defer fun(fn: fun()): any
---@field errdefer fun(fn: fun(err: any)): any
---@field fs MakacFs
---@field time MakacTime
---@field env MakacEnv
---@field json MakacJson
---@field luals_stub string
---@field luals_setup fun()
---@field load_packages fun(data_dir?: string): integer
---@field fetch_all fun(data_dir?: string): integer
---@field read_package_defs fun(data_dir?: string): table[]
---@field resolve_pkg_dir fun(def: table, data_dir?: string): string
---@field run_action fun(name: string, args: any): StepResult
---@field close_all_targets fun()
---@field registry table
---@field pkg_dirs table<string, string>
---@field listdir fun(path: string|Path): FsEntry[]|nil, string?

---@type Makac
makac = {}

-- --- steps (design/steps.md) ----------------------------------------------

---@class StepSpec
---@field name? string
---@field uses string
---@field with? table<string, any>
---@field target? Target|string

---@class StepResult
---@field err? string
---@field changed boolean
---@field skipped boolean
---@field out table<string, any>

---@param spec StepSpec
---@return StepResult
function step(spec) end
