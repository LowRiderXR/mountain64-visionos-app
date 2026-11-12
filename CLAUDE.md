# Working rules for AI agents

- Everything in this repository is English: comments, log and output lines, script messages, identifiers, file names, README, commit messages.
- No round codes (such as M4a.5c) and no references to private documentation in code or comments.
- Never commit or push; the maintainer reviews and commits.
- Do not edit AvpCeleste64.xcodeproj/project.pbxproj or the schemes; describe the change for Xcode instead.
- Celeste 64 sources change only through Patches/celeste64-usefoster.patch; keep the original line endings (CRLF in Player.cs, Game.cs, Cutscene.cs; LF elsewhere).
- Never add FMOD SDK files or binaries to the repository.
- Measure performance only with optimized builds (Release or Diagnostics), never Debug.
