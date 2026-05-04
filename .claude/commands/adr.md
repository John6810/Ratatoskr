---
description: Create a new Architecture Decision Record under docs/adr/ with auto-incremented number and Nygard template
argument-hint: <short title of the decision>
allowed-tools: Bash(ls:*), Bash(find:*), Bash(rg:*), Bash(cat:*), Bash(date:*), Read, Glob, Write
---

## Existing ADRs
!`ls docs/adr/ 2>/dev/null || echo "(no ADRs yet)"`

## Today's date
!`date +%Y-%m-%d`

## Your task

Create a new Architecture Decision Record for the following decision:

**Title**: $ARGUMENTS

### Step 1 — Determine the next ADR number

Look at the existing ADRs above. They follow the pattern `NNNN-slug.md` (zero-padded 4 digits). Pick the next available integer. If none exist, start at `0001`.

### Step 2 — Build the slug

Take the title, lowercase it, replace spaces with hyphens, drop punctuation, keep it under 60 characters. Example:

- Title: `Use FrankenPHP instead of nginx + php-fpm`
- Slug: `use-frankenphp-instead-of-nginx-php-fpm`
- Filename: `docs/adr/0001-use-frankenphp-instead-of-nginx-php-fpm.md`

### Step 3 — Create the file with this template

```markdown
# ADR-NNNN: <Title>

- **Status**: Proposed
- **Date**: YYYY-MM-DD
- **Deciders**: <leave blank for now>
- **Tags**: <one or two short tags, e.g. `runtime`, `database`, `ci`>

## Context

What problem are we solving? What constraints apply (technical, legal, operational)? What alternatives were considered? Two or three short paragraphs.

## Decision

What did we decide? One paragraph, declarative voice.

## Consequences

### Positive
- ...
- ...

### Negative
- ...

### Neutral
- ...

## Alternatives considered

- **Option A**: brief description, why rejected.
- **Option B**: brief description, why rejected.

## References

- Link to the upstream doc that informed the decision.
- Link to a related issue or PR if applicable.
```

### Step 4 — Pre-fill what you can

If the title or context provides enough information, pre-fill the **Context**, **Decision**, and **Alternatives considered** sections with first-draft content. Mark anything you guessed with `<!-- VERIFY -->` so the user knows what to check.

If the title is too vague to draft anything, leave the template empty with TODO comments and ask the user one focused question.

### Step 5 — Output

Write the file using the `Write` tool. Then print:

```
✅ Created docs/adr/<filename>
Status: Proposed — review and update before committing.
```

### Hard rules

- **Status starts at `Proposed`**, never `Accepted` automatically. The user accepts an ADR by editing it after review.
- **Never overwrite an existing ADR.** If the slug collides, append a `-v2` suffix or ask the user.
- **Keep ADRs short.** A good ADR is one screen of markdown. If you need more, the decision is probably actually two decisions — split.
- **Don't argue both sides at length.** ADRs document decisions, not debates. Alternatives section is bullet points, not essays.
