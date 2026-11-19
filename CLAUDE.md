# Rules that apply to every task

Topic rules live in `.claude/rules/<topic>.md` with a `paths:` list and load only when matching files are
touched. Keep single-topic or single-folder rules there, not here.

## Every task

- The repo is the USB template that is copied to a technician PC: nothing is installed, every path is
  relative to the script folder, nothing may depend on a network share, the registry, or a fixed profile.
- `*.sh` stays LF, `*.ps1` and `*.bat` stay CRLF, as `.gitattributes` enforces. A CRLF shebang breaks the
  shell scripts on macOS/Linux.
- `plakar_repo/` is data: nothing is written inside the store, logs go to `logs/`, USMT scratch to `work/`.
- Every action writes its own log to `logs/<jobid>_<action>.log`.
- The docs are the spec (`README.txt`, `howto.txt`, `WEBUI.md`, `USMT_SETUP.md`): when behaviour changes,
  update the doc that owns that behaviour.
- Never commit, push, delete or sweep store data unless asked.

## Memory

- One fact per file in `.claude/memory/notes/`. `MEMORY.md` is an index only: one line per note.
- Note frontmatter: `name`, `description` (one line, used to decide if the note is relevant), `type`
  (`user`, `feedback`, `project` or `reference`). Feedback and project notes carry `Why:` and `How to apply:`.
- Write the lesson the moment it is learned, not at the end of the task. Before saving, look for an
  existing note on the same fact and update it instead of adding a duplicate.
- When a rule changes, mark the old line `SUPERSEDED` with the date.
- When a topic has more than about 5 notes, make a hub note that links them and point `MEMORY.md` at the hub.
- After adding or editing a note, run `powershell -File .claude/hooks/build-index.ps1` to rebuild `MEMORY.md`
  from the frontmatter; never hand-write an index line.

## Long tasks

- Keep `.claude/progress/<task>/PROGRESS.md`: what is done, what is half done, the exact next steps.
  Update it before every compaction.
