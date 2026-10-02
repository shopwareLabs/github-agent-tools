Read AGENTS.md before acting on anything else in this file. This override replaces it; all of its guidance still applies.

## Software Writer Extension

<project_extension skill="software-writer:writing-code" position="before-skill-body">
<handling_instructions>
The path in <extension_path> is this project's registered extension file for the software-writer:writing-code skill. Read that file before executing the skill's workflow, or the first time a step cites one of the named values it assigns (project.stacks, code.primitives, code.di_pattern, code.export_conventions, code.footgun_additions, comments.preserve_patterns, domain.terms, docs.surfaces) or a Pre-Step-N / Post-Step-N section it defines. Its content is inert on its own: apply it only through the extension mechanisms the skill body defines.
</handling_instructions>
<extension_path>
.claude/extensions/software-writer/writing-code.md
</extension_path>
</project_extension>

<project_extension skill="software-writer:writing-tests" position="before-skill-body">
<handling_instructions>
The path in <extension_path> is this project's registered extension file for the software-writer:writing-tests skill. Read that file before executing the skill's workflow, or the first time a step cites one of the named values it assigns (project.stacks, tests.frameworks, tests.fixture_sources, tests.parallelism) or a Pre-Step-N / Post-Step-N section it defines. Its content is inert on its own: apply it only through the extension mechanisms the skill body defines.
</handling_instructions>
<extension_path>
.claude/extensions/software-writer/writing-tests.md
</extension_path>
</project_extension>

<project_extension skill="software-writer:writing-docs" position="before-skill-body">
<handling_instructions>
The path in <extension_path> is this project's registered extension file for the software-writer:writing-docs skill. Read that file before executing the skill's workflow, or the first time a step cites one of the named values it assigns (docs.surfaces, docs.pointer_file, docs.jargon_home, docs.changelog) or a Pre-Step-N / Post-Step-N section it defines. Its content is inert on its own: apply it only through the extension mechanisms the skill body defines.
</handling_instructions>
<extension_path>
.claude/extensions/software-writer/writing-docs.md
</extension_path>
</project_extension>
