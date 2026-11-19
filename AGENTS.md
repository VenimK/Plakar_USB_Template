# Project instructions

The single source of the project rules is `CLAUDE.md`; read it first. Topic rules are one file per topic in
`.claude/rules/`. OpenCode loads this file always and cannot scope a rule by path, so the mapping below says
which rule file applies to which files; a nested `AGENTS.md` stub in a topic's own folder repeats the pointer
when that folder is read. `.claude/` is not committed — it is this machine's agent config, and the template
is copied to technician PCs.

| Files | Rule file to read |
| --- | --- |
| `*.ps1`, `*.sh`, `*.xml`, `USMT/` | `.claude/rules/usmt.md` |
| `*.ps1`, `*.sh`, `*.bat`, `web/` | `.claude/rules/hosts.md` |
| `webserver.ps1`, `web/` | `.claude/rules/webui.md` |
| `reclaim.ps1`, `plakar_repo/`, anything maintenance or gratie | `.claude/rules/plakar-store.md` |
| `README.txt`, `howto.txt`, `WEBUI.md`, `USMT_SETUP.md` | `.claude/rules/docs.md` |

`.claude/memory/MEMORY.md` is the note index; `.claude/progress/<task>/PROGRESS.md` is the state file for a
long task.
