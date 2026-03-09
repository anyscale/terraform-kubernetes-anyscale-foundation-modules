---
name: create-skill
description: Create a new Claude Code skill (slash command) for this project. Use when the user wants to add a new skill, slash command, or automation to the .claude/skills directory.
argument-hint: [skill-name]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# Create a New Claude Code Skill

You are a skill creator for Claude Code. Your job is to create well-structured, useful skills in `.claude/skills/`.

## Process

1. **Understand the request**: Ask clarifying questions if the skill name or purpose is unclear from `$ARGUMENTS`.
2. **Check for conflicts**: Look in `.claude/skills/` to ensure no skill with the same name already exists.
3. **Design the skill**: Determine the appropriate frontmatter fields and instructions.
4. **Create the skill**: Write the `SKILL.md` file in `.claude/skills/<skill-name>/SKILL.md`.

## Skill File Format

Every skill must be a `SKILL.md` file with YAML frontmatter and markdown instructions:

```yaml
---
name: <skill-name>           # Required. Lowercase letters, numbers, hyphens only (max 64 chars)
description: <description>    # Recommended. What skill does and when Claude should auto-trigger it.
argument-hint: <hint>         # Optional. Shown during autocomplete, e.g., [filename] [format]
disable-model-invocation: false  # Optional. Set true to prevent Claude auto-triggering
user-invocable: true          # Optional. Set false to hide from / menu (model-only)
allowed-tools: Read, Grep     # Optional. Tools Claude can use without permission prompts
context: fork                 # Optional. Set to fork to run in isolated subagent context
agent: Explore                # Optional. Subagent type when using context: fork
---

# Skill Title

Instructions for Claude when this skill is invoked...
```

## Guidelines

- Keep skill names short and descriptive (e.g., `deploy`, `review-pr`, `run-tests`)
- Write clear, actionable instructions in the markdown body
- Use `$ARGUMENTS` to reference user-provided arguments
- Set `allowed-tools` to only what the skill needs
- Set `disable-model-invocation: true` for dangerous or side-effect-heavy skills
- Use `context: fork` for exploratory or read-only skills that shouldn't pollute main context
- Include concrete steps and expected output format in the instructions
- Reference project-specific paths and conventions where relevant

## After Creation

After creating the skill, inform the user:
- The skill file path
- How to invoke it: `/<skill-name>` or `/<skill-name> [args]`
- A brief summary of what the skill does
