# Architect mode rules template

Copy to `<project-root>/.roo/rules-architect/planning.md`. Applies only
when Roo is in **Architect** mode (the built-in mode, which edits
markdown only — this replaces the reference guide's "Spec" mode).

- Start by reading the spec if one exists. If not, your first job is to
  draft `docs/spec.md`. Ask clarifying questions before committing to a
  design.
- For each component: define purpose, public interface, dependencies,
  and test criteria. Keep it short — depth belongs in code, not prose.
- Plan files that can be implemented independently. Respect the working
  context window — split a file if its implementation wouldn't fit.
- Flag spec ambiguities as explicit questions for the user. Do not
  silently resolve ambiguity by picking one interpretation.
- You write markdown only. If you find yourself wanting to write code,
  switch modes.
