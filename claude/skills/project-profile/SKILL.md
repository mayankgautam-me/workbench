---
name: project-profile
description: Detect what kind of project the current folder is (Flutter, React Native, Swift, Android, Tauri, Svelte, Next.js, Zephyr, Cortex-M, ESP-IDF, PlatformIO, embedded Rust, KiCad, Go, AI/ML, data, MQTT) and pick the matching agents and skills for the session. Runs automatically at session start through a hook; use this skill to re-run it after changing folder, after adding a new part to a project, or when asked "which agent should this project use".
---

# Project profile

Run the detector on the project folder:

```bash
~/.claude/hooks/detect-project.sh "$PWD"
```

Pass a different folder as the argument to profile another project.

Then:

1. Tell the user in one or two lines what was detected.
2. For the rest of the session, hand matching work to the agents it names and load the skills it names before starting that kind of task. A skill or agent the user names in a request always wins.
3. If it prints nothing, no known project type was found. Say so and fall back to the "Skill routing" section of `~/.claude/CLAUDE.md`.

The detector only reads file names and a few manifest files, three levels deep. To teach it a new project type, add a rule to `~/.claude/hooks/detect-project.sh`.
